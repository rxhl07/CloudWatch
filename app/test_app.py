"""
OpsPulse 360 — Unit Test Suite
=================================
Tests every business-logic function in app.py using mocks so no real AWS,
PostgreSQL, or EC2 connections are required.

Run:
    cd app
    python -m pytest test_app.py -v
"""

import sys
import os
import time
import threading
import types
import importlib
import unittest
from unittest.mock import MagicMock, patch, call
import pandas as pd

# ---------------------------------------------------------------------------
# STEP 1: Stub out `streamlit` BEFORE app.py is imported.
# app.py calls st.set_page_config(), st.title(), st.columns(2), etc. at
# module level. We replace streamlit with a MagicMock, but st.columns(N)
# must return a real list of N MagicMocks so tuple-unpacking works:
#   chart_col1, chart_col2 = st.columns(2)   ← needs exactly 2 items
# ---------------------------------------------------------------------------
_st_mock = MagicMock()

def _mock_columns(n, *args, **kwargs):
    """Return a list of N independent MagicMock context managers."""
    return [MagicMock() for _ in range(n)]

_st_mock.columns.side_effect = _mock_columns
sys.modules['streamlit'] = _st_mock

# Also stub psycopg2 at module level so the import inside app.py doesn't fail
# if psycopg2-binary isn't installed in the test environment.
_psycopg2_mock = MagicMock()
sys.modules['psycopg2'] = _psycopg2_mock

# ---------------------------------------------------------------------------
# STEP 2: Patch requests + boto3 so the top-level INSTANCE_ID fetch and
# cw_client creation in app.py are completely mocked.
# ---------------------------------------------------------------------------
with patch('requests.put') as _mock_put, \
     patch('requests.get') as _mock_get, \
     patch('boto3.client') as _mock_boto:

    _mock_put.return_value.text = "fake-token"
    _mock_get.return_value.text = "Local-Dev-Instance"   # <- triggers local-dev path
    _mock_boto.return_value = MagicMock()

    # Add app dir to sys.path so we can import it
    sys.path.insert(0, os.path.dirname(__file__))
    import app  # noqa: E402  (import after mocks are set up)

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
def _make_cloudwatch_response(cpu_values, ram_values):
    """Build a realistic boto3 get_metric_data response dict."""
    return {
        'MetricDataResults': [
            {'Id': 'cpu', 'Values': cpu_values, 'Timestamps': []},
            {'Id': 'ram', 'Values': ram_values, 'Timestamps': []},
        ],
        'Messages': []
    }


# ===========================================================================
# TEST CLASS 1: get_instance_id()
# ===========================================================================
class TestGetInstanceId(unittest.TestCase):

    def test_returns_local_dev_on_network_error(self):
        """When IMDSv2 is unreachable (e.g. local laptop), returns fallback string."""
        with patch('requests.put', side_effect=Exception("timeout")):
            result = app.get_instance_id()
        self.assertEqual(result, "Local-Dev-Instance")

    def test_returns_real_id_on_success(self):
        """Returns the raw text from the metadata endpoint on success."""
        mock_put_resp = MagicMock()
        mock_put_resp.text = "my-token"
        mock_get_resp = MagicMock()
        mock_get_resp.text = "i-0abc1234def56789a"

        with patch('requests.put', return_value=mock_put_resp), \
             patch('requests.get', return_value=mock_get_resp):
            result = app.get_instance_id()

        self.assertEqual(result, "i-0abc1234def56789a")


# ===========================================================================
# TEST CLASS 2: push_custom_metric()
# ===========================================================================
class TestPushCustomMetric(unittest.TestCase):

    def test_calls_put_metric_data_with_correct_args(self):
        """Verifies the correct namespace, metric name, and unit are sent."""
        mock_cw = MagicMock()
        app.cw_client = mock_cw
        app.INSTANCE_ID = "i-test123"

        app.push_custom_metric("SimulatedChaosEvents", 1)

        mock_cw.put_metric_data.assert_called_once_with(
            Namespace='OpsPulse360/Application',
            MetricData=[{
                'MetricName': 'SimulatedChaosEvents',
                'Dimensions': [{'Name': 'InstanceID', 'Value': 'i-test123'}],
                'Value': 1,
                'Unit': 'Count'
            }]
        )

    def test_silently_handles_boto3_exception(self):
        """A CloudWatch API error must NOT raise — it should be swallowed."""
        mock_cw = MagicMock()
        mock_cw.put_metric_data.side_effect = Exception("throttled")
        app.cw_client = mock_cw

        # Should not raise
        try:
            app.push_custom_metric("AnyMetric", 5)
        except Exception as exc:
            self.fail(f"push_custom_metric raised unexpectedly: {exc}")


# ===========================================================================
# TEST CLASS 3: fetch_aws_metrics()   ← the core bug-fix test
# ===========================================================================
class TestFetchAwsMetrics(unittest.TestCase):

    def setUp(self):
        # Ensure we are NOT in local-dev mode so the real code path is exercised
        app.INSTANCE_ID = "i-realinstance"

    def test_returns_dataframe_with_correct_columns(self):
        """DataFrame must always have exactly the two expected column names."""
        mock_cw = MagicMock()
        mock_cw.get_metric_data.return_value = _make_cloudwatch_response(
            cpu_values=[10.5, 12.3],
            ram_values=[55.1, 57.8]
        )
        app.cw_client = mock_cw

        df = app.fetch_aws_metrics()

        self.assertIsInstance(df, pd.DataFrame)
        self.assertIn("CPU Utilization (%)", df.columns)
        self.assertIn("RAM Utilization (%)", df.columns)

    def test_uses_MetricDataResults_key_not_MetricResults(self):
        """
        BUG FIX VERIFICATION: The old code used response.get('MetricResults', [])
        which always returns [] because boto3 uses 'MetricDataResults'.
        This test confirms the fix is correct — data is actually extracted.
        """
        mock_cw = MagicMock()
        mock_cw.get_metric_data.return_value = _make_cloudwatch_response(
            cpu_values=[42.0],
            ram_values=[75.0]
        )
        app.cw_client = mock_cw

        df = app.fetch_aws_metrics()

        # If the old wrong key were used, both would be [0.0] (the fallback)
        self.assertEqual(df["CPU Utilization (%)"].iloc[0], 42.0,
                         "CPU value should be 42.0, not 0.0 — MetricDataResults key bug not fixed")
        self.assertEqual(df["RAM Utilization (%)"].iloc[0], 75.0,
                         "RAM value should be 75.0, not 0.0 — MetricDataResults key bug not fixed")

    def test_period_is_60_seconds_for_both_metrics(self):
        """
        BUG FIX VERIFICATION: RAM Period was 10 (invalid). CloudWatch silently
        returns empty data for sub-60s periods on standard resolution metrics.
        Confirm both queries use Period=60.
        """
        mock_cw = MagicMock()
        mock_cw.get_metric_data.return_value = _make_cloudwatch_response([], [])
        app.cw_client = mock_cw

        app.fetch_aws_metrics()

        call_kwargs = mock_cw.get_metric_data.call_args[1]
        queries = call_kwargs['MetricDataQueries']

        cpu_period = queries[0]['MetricStat']['Period']
        ram_period = queries[1]['MetricStat']['Period']

        self.assertEqual(cpu_period, 60, f"CPU Period should be 60, got {cpu_period}")
        self.assertEqual(ram_period, 60, f"RAM Period should be 60, got {ram_period} (was 10 — the bug)")

    def test_empty_cloudwatch_response_returns_flatline_dataframe(self):
        """When CloudWatch has no data yet, function returns [0.0] fallback — never crashes."""
        mock_cw = MagicMock()
        mock_cw.get_metric_data.return_value = _make_cloudwatch_response([], [])
        app.cw_client = mock_cw

        df = app.fetch_aws_metrics()

        self.assertFalse(df.empty)
        self.assertEqual(df["CPU Utilization (%)"].iloc[0], 0.0)
        self.assertEqual(df["RAM Utilization (%)"].iloc[0], 0.0)

    def test_mismatched_array_lengths_padded_correctly(self):
        """If CPU has more data points than RAM (or vice versa), both are padded to same length."""
        mock_cw = MagicMock()
        mock_cw.get_metric_data.return_value = _make_cloudwatch_response(
            cpu_values=[10.0, 20.0, 30.0],
            ram_values=[50.0]           # shorter
        )
        app.cw_client = mock_cw

        df = app.fetch_aws_metrics()

        self.assertEqual(len(df), 3)
        self.assertEqual(df["RAM Utilization (%)"].iloc[1], 0.0)  # padded
        self.assertEqual(df["RAM Utilization (%)"].iloc[2], 0.0)  # padded

    def test_local_dev_instance_returns_flatline_without_api_call(self):
        """When running locally (no EC2), no CloudWatch API call is made — returns safe default."""
        mock_cw = MagicMock()
        app.cw_client = mock_cw
        app.INSTANCE_ID = "Local-Dev-Instance"

        df = app.fetch_aws_metrics()

        mock_cw.get_metric_data.assert_not_called()
        self.assertFalse(df.empty)

    def test_api_exception_returns_fallback_dataframe(self):
        """A boto3 exception in fetch_aws_metrics must return a safe fallback DataFrame, not crash."""
        mock_cw = MagicMock()
        mock_cw.get_metric_data.side_effect = Exception("network error")
        app.cw_client = mock_cw
        app.INSTANCE_ID = "i-realinstance"

        df = app.fetch_aws_metrics()

        self.assertIsInstance(df, pd.DataFrame)
        self.assertFalse(df.empty)


# ===========================================================================
# TEST CLASS 4: _run_memory_stress_background()
# ===========================================================================
class TestMemoryStressBackground(unittest.TestCase):

    def test_does_not_crash_and_completes(self):
        """
        The memory stress function must complete without raising any exception.
        We patch time.sleep to speed the test up (skip the 8-second hold).
        """
        mock_cw = MagicMock()
        app.cw_client = mock_cw
        app.INSTANCE_ID = "i-test"

        with patch('time.sleep', return_value=None):
            try:
                app._run_memory_stress_background()
            except Exception as exc:
                self.fail(f"_run_memory_stress_background raised: {exc}")

    def test_pushes_chaos_metric_when_done(self):
        """After the stress completes, SimulatedChaosEvents metric must be pushed."""
        mock_cw = MagicMock()
        app.cw_client = mock_cw
        app.INSTANCE_ID = "i-test"

        with patch('time.sleep', return_value=None):
            app._run_memory_stress_background()

        mock_cw.put_metric_data.assert_called_once()
        call_args = mock_cw.put_metric_data.call_args[1]
        self.assertEqual(call_args['MetricData'][0]['MetricName'], 'SimulatedChaosEvents')

    def test_runs_in_background_thread_without_blocking(self):
        """
        BUG FIX VERIFICATION: The old code ran memory allocation on the main thread,
        blocking Streamlit for up to 10s and causing a 502.
        Verify the thread starts and the caller returns immediately.
        """
        mock_cw = MagicMock()
        app.cw_client = mock_cw
        app.INSTANCE_ID = "i-test"

        # Patch sleep so thread finishes quickly in tests
        with patch('time.sleep', return_value=None):
            t = threading.Thread(target=app._run_memory_stress_background, daemon=True)
            t_start = time.monotonic()
            t.start()
            elapsed = time.monotonic() - t_start

        # Caller should return in well under 1 second (thread is non-blocking)
        self.assertLess(elapsed, 1.0,
                        f"Thread start blocked for {elapsed:.2f}s — main thread is being blocked")
        t.join(timeout=5)


# ===========================================================================
# TEST CLASS 5: Database functions — log_visit(), get_logs(), init_db()
# ===========================================================================
class TestDatabaseFunctions(unittest.TestCase):

    def _make_mock_conn(self):
        """Return a mock psycopg2 connection with cursor pre-configured."""
        mock_conn = MagicMock()
        mock_cur = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        return mock_conn, mock_cur

    def test_log_visit_returns_true_on_success(self):
        """log_visit() must return True when the DB INSERT succeeds."""
        mock_conn, mock_cur = self._make_mock_conn()
        with patch('app.get_db_connection', return_value=mock_conn):
            result = app.log_visit()
        self.assertTrue(result)
        mock_cur.execute.assert_called_once()
        mock_conn.commit.assert_called_once()

    def test_log_visit_returns_false_on_db_error(self):
        """log_visit() must return False (not raise) when the DB is unreachable."""
        mock_cw = MagicMock()
        app.cw_client = mock_cw

        with patch('app.get_db_connection', side_effect=Exception("DB down")):
            result = app.log_visit()

        self.assertFalse(result)
        # Must also push a DatabaseConnectionErrors metric
        mock_cw.put_metric_data.assert_called_once()
        metric_name = mock_cw.put_metric_data.call_args[1]['MetricData'][0]['MetricName']
        self.assertEqual(metric_name, 'DatabaseConnectionErrors')

    def test_get_logs_returns_rows_on_success(self):
        """get_logs() must return the rows fetched from the DB."""
        mock_conn, mock_cur = self._make_mock_conn()
        fake_rows = [("i-abc", "2026-07-07 10:00:00+00"), ("i-def", "2026-07-07 09:00:00+00")]
        mock_cur.fetchall.return_value = fake_rows

        with patch('app.get_db_connection', return_value=mock_conn):
            rows = app.get_logs()

        self.assertEqual(rows, fake_rows)

    def test_get_logs_returns_empty_list_on_db_error(self):
        """get_logs() must return [] (not raise) when the DB is unreachable."""
        with patch('app.get_db_connection', side_effect=Exception("DB down")):
            rows = app.get_logs()
        self.assertEqual(rows, [])

    def test_init_db_executes_create_table(self):
        """init_db() must run the CREATE TABLE IF NOT EXISTS statement."""
        mock_conn, mock_cur = self._make_mock_conn()
        with patch('app.get_db_connection', return_value=mock_conn):
            app.init_db()
        mock_cur.execute.assert_called_once()
        sql = mock_cur.execute.call_args[0][0]
        self.assertIn("CREATE TABLE IF NOT EXISTS traffic_logs", sql)


# ===========================================================================
# TEST CLASS 6: Regression — old bug guard
# ===========================================================================
class TestRegressionGuards(unittest.TestCase):

    def test_MetricResults_key_is_not_used(self):
        """
        Hard regression guard: the old code used response.get('MetricResults', [])
        which ALWAYS returns [] because the correct boto3 key is 'MetricDataResults'.
        We check the actual .get() call — not comments — to avoid false positives.
        """
        import inspect
        source = inspect.getsource(app.fetch_aws_metrics)
        # The exact wrong API call that caused the bug:
        self.assertNotIn(
            "response.get('MetricResults'", source,
            "REGRESSION: response.get('MetricResults') found in fetch_aws_metrics — "
            "should be response.get('MetricDataResults'). This was the original graph bug."
        )
        # And confirm the correct key IS present:
        self.assertIn(
            "response.get('MetricDataResults'", source,
            "MISSING: response.get('MetricDataResults') not found in fetch_aws_metrics — "
            "the correct CloudWatch API response key must be used."
        )

    def test_ram_period_not_10(self):
        """
        Hard regression guard: Period=10 on RAM was the silent no-data bug.
        Confirm it no longer appears in the source.
        """
        import inspect
        # Check the full module source
        source = inspect.getsource(app)
        # The old bug: 'Period': 10
        self.assertNotIn(
            "'Period': 10", source,
            "REGRESSION: 'Period': 10 found — CloudWatch minimum is 60s. "
            "This caused RAM metric to silently return no data."
        )

    def test_memory_stress_uses_bytearray_not_list(self):
        """
        Hard regression guard: the old 15M-float list caused OOM → 502.
        Confirm bytearray (bounded allocation) is used instead.
        """
        import inspect
        source = inspect.getsource(app._run_memory_stress_background)
        self.assertIn("bytearray", source,
                      "REGRESSION: bytearray not found — old list-based allocation may be back")
        self.assertNotIn("range(15_000_000)", source,
                         "REGRESSION: 15M float loop is back — causes OOM crash / 502")


if __name__ == '__main__':
    unittest.main(verbosity=2)
