#!/bin/bash
# Redirect all outputs and errors to a startup log file for initial debugging
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "========================================="
echo "STARTING OPSPULSE 360 NODE SETUP"
echo "========================================="

# 1. Update OS Packages and Install Python Essentials
apt-get update -y
apt-get install -y python3-pip python3-dev git wget

# 2. Setup Application Directories
mkdir -p /opt/opspulse/app
mkdir -p /scripts

# 3. Create Application Requirements File
cat << 'EOF' > /opt/opspulse/app/requirements.txt
streamlit==1.35.0
psycopg2-binary==2.9.9
boto3==1.34.115
pandas==2.2.2
EOF

# 4. Inject Visual Application Code (app.py) directly inline
cat << 'EOF' > /opt/opspulse/app/app.py
import streamlit as st
import psycopg2
import boto3
import os
import time
import threading
import requests
import pandas as pd
from datetime import datetime, timedelta

# ==========================================
# 1. SYSTEM METADATA FETCH (EC2 Context)
# ==========================================
def get_instance_id():
    """Fetches the unique EC2 Instance ID from AWS IMDSv2 Metadata service."""
    try:
        token_url = "http://169.254.169.254/latest/api/token"
        token_headers = {"X-aws-ec2-metadata-token-ttl-seconds": "21600"}
        token_response = requests.put(token_url, headers=token_headers, timeout=2)
        token = token_response.text

        metadata_url = "http://169.254.169.254/latest/meta-data/instance-id"
        metadata_headers = {"X-aws-ec2-metadata-token": token}
        instance_response = requests.get(metadata_url, headers=metadata_headers, timeout=2)
        return instance_response.text
    except Exception:
        return "Local-Dev-Instance"

INSTANCE_ID = get_instance_id()
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Initialize CloudWatch Client via Boto3
cw_client = boto3.client('cloudwatch', region_name=AWS_REGION)

# ==========================================
# 2. DATABASE UTILITIES & LOGGING
# ==========================================
def get_db_connection():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST"),
        database=os.environ.get("DB_NAME", "opspulse_db"),
        user=os.environ.get("DB_USER", "opspulse_admin"),
        password=os.environ.get("DB_PASSWORD")
    )

def init_db():
    """Creates the traffic monitoring table if it doesn't exist."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS traffic_logs (
                id SERIAL PRIMARY KEY,
                instance_id VARCHAR(50),
                timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        st.error(f"Database initialization failed: {e}")

def log_visit():
    """Inserts a timestamped record into PostgreSQL."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("INSERT INTO traffic_logs (instance_id) VALUES (%s);", (INSTANCE_ID,))
        conn.commit()
        cur.close()
        conn.close()
        return True
    except Exception:
        push_custom_metric("DatabaseConnectionErrors", 1)
        return False

def get_logs():
    """Retrieves the last 10 traffic hits recorded in the database."""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT instance_id, timestamp FROM traffic_logs ORDER BY id DESC LIMIT 10;")
        rows = cur.fetchall()
        cur.close()
        conn.close()
        return rows
    except Exception:
        return []

# ==========================================
# 3. AWS CLOUDWATCH METRICS INTEGRATION
# ==========================================
def push_custom_metric(metric_name, value):
    """Pushes application-level metrics up to AWS CloudWatch."""
    try:
        cw_client.put_metric_data(
            Namespace='OpsPulse360/Application',
            MetricData=[
                {
                    'MetricName': metric_name,
                    'Dimensions': [{'Name': 'InstanceID', 'Value': INSTANCE_ID}],
                    'Value': value,
                    'Unit': 'Count'
                },
            ]
        )
    except Exception as e:
        print(f"Failed pushing metric: {e}")

def fetch_aws_metrics():
    """Pulls real-time tracking data straight out of AWS CloudWatch for this EC2 node."""
    if INSTANCE_ID == "Local-Dev-Instance":
        return pd.DataFrame({"CPU Utilization (%)": [0.0], "RAM Utilization (%)": [0.0]})

    try:
        end_time = datetime.utcnow()
        # Look back 30 minutes to ensure fresh data points are always in range
        metric_start_time = end_time - timedelta(minutes=30)

        response = cw_client.get_metric_data(
            MetricDataQueries=[
                {
                    'Id': 'cpu',
                    'MetricStat': {
                        'Metric': {
                            'Namespace': 'AWS/EC2',
                            'MetricName': 'CPUUtilization',
                            'Dimensions': [{'Name': 'InstanceId', 'Value': INSTANCE_ID}]
                        },
                        # Period must be >= 60 seconds for standard CloudWatch metrics
                        'Period': 60,
                        'Stat': 'Average'
                    }
                },
                {
                    'Id': 'ram',
                    'MetricStat': {
                        'Metric': {
                            'Namespace': 'CWAgent',
                            'MetricName': 'mem_used_percent',
                            'Dimensions': [{'Name': 'InstanceId', 'Value': INSTANCE_ID}]
                        },
                        # FIX: Was 10 -- CloudWatch minimum is 60s for standard resolution
                        'Period': 60,
                        'Stat': 'Average'
                    }
                }
            ],
            StartTime=metric_start_time,
            EndTime=end_time
        )

        cpu_values = []
        ram_values = []

        # FIX: Correct key is 'MetricDataResults', NOT 'MetricResults'
        # The old key silently returned [] every time -> blank/zero graphs
        for result in response.get('MetricDataResults', []):
            if result['Id'] == 'cpu':
                cpu_values = result.get('Values', [])
            elif result['Id'] == 'ram':
                ram_values = result.get('Values', [])

        # If lists are empty (server just booted / no data yet), show a flatline placeholder
        if not cpu_values:
            cpu_values = [0.0]
        if not ram_values:
            ram_values = [0.0]

        # Pad arrays so they match in length for the Streamlit chart
        max_len = max(len(cpu_values), len(ram_values))
        cpu_padded = cpu_values + [0.0] * (max_len - len(cpu_values))
        ram_padded = ram_values + [0.0] * (max_len - len(ram_values))

        return pd.DataFrame({
            "CPU Utilization (%)": cpu_padded,
            "RAM Utilization (%)": ram_padded
        })

    except Exception as e:
        st.sidebar.error(f"CloudWatch API Error: {str(e)}")
        return pd.DataFrame({"CPU Utilization (%)": [0.0], "RAM Utilization (%)": [0.0]})


def _run_memory_stress_background():
    """
    Runs a SAFE, bounded memory stress simulation in a background daemon thread.

    FIX: The old code allocated ~420 MB (15M Python floats * 28 bytes) on the
    Streamlit main thread, OOM-killing the process and causing a 502 Bad Gateway.
    This version:
      1. Runs in a daemon thread -- Streamlit's rendering loop is never blocked.
      2. Caps allocation at 50 MB via bytearray -- safe on any t3.micro+ instance.
      3. Holds for 8 seconds so at least one 60s CW window captures the spike,
         then explicitly releases memory so GC reclaims it immediately.
    """
    try:
        # 50 MB allocation -- safe on any t3.micro+ instance
        leak_block = bytearray(50 * 1024 * 1024)
        # Touch every page to ensure the OS actually commits the memory
        for i in range(0, len(leak_block), 4096):
            leak_block[i] = 1
        # Hold long enough for at least one CW 60-second collection window to capture it
        time.sleep(8)
        del leak_block
    except Exception:
        pass
    finally:
        push_custom_metric("SimulatedChaosEvents", 1)


# ==========================================
# 4. STREAMLIT INTERACTIVE FRONTEND UI
# ==========================================
st.set_page_config(page_title="OpsPulse 360 | Monitor Portal", layout="wide")

st.title("📊 OpsPulse 360: Live SRE Monitoring & Metrics Portal")
st.markdown(f"**Running on Cluster Nodes:** `{INSTANCE_ID}` | **Target Region:** `{AWS_REGION}`")
st.write("---")

init_db()
db_active = log_visit()

if db_active:
    st.success("🟢 SYSTEM STATUS: FULLY HEALTHY (App connected to Database Vault)")
else:
    st.error("🔴 SYSTEM STATUS: DEGRADED (Database Connection Failed - Metric Emitted)")

# Telemetry
st.subheader("🖥️ Real-Time AWS Telemetry (Pulled Directly from CloudWatch APIs)")
metrics_df = fetch_aws_metrics()

if not metrics_df.empty:
    chart_col1, chart_col2 = st.columns(2)
    with chart_col1:
        st.write("**Hypervisor CPU Load Timeline**")
        st.line_chart(metrics_df["CPU Utilization (%)"])
    with chart_col2:
        st.write("**CloudWatch Agent Memory (RAM) Tracker**")
        st.line_chart(metrics_df["RAM Utilization (%)"])
else:
    st.warning("Gathering initial telemetry coordinates from CloudWatch pipelines...")

st.write("---")

col1, col2 = st.columns(2)
with col1:
    st.subheader("📈 Live Transaction Database Logs")
    logs = get_logs()
    if logs:
        st.table([{"Processing Instance ID": row[0], "Timestamp (UTC)": str(row[1])} for row in logs])
    else:
        st.info("No transaction traffic logs detected yet.")

with col2:
    st.subheader("⚠️ Chaos Engineering Testing Panel")

    if st.button("🔥 Simulate Server Memory Leak"):
        st.warning("Initiating memory stress simulation... RAM Utilization will rise on CloudWatch.")
        # FIX: Run stress in a daemon background thread -- main thread is never blocked,
        # so the UI (graphs included) continues rendering immediately after click.
        # Allocation is capped at 50 MB to prevent OOM crash (old code used ~420 MB).
        stress_thread = threading.Thread(target=_run_memory_stress_background, daemon=True)
        stress_thread.start()
        st.success("✅ Chaos burst launched safely in background. Refresh graphs in ~30s to see the RAM spike!")

    if st.button("🔌 Simulate Database Connection Failure"):
        st.error("Severing application context hooks. Forcing error routing logic...")
        for _ in range(5):
            push_custom_metric("DatabaseConnectionErrors", 1)
        st.write("Sent 5 synthetic `DatabaseConnectionErrors` metrics to CloudWatch.")

if st.button("🔄 Force Refresh Visual Graphs"):
    st.rerun()
EOF

# 5. Install Python dependencies globally
pip3 install --break-system-packages -r /opt/opspulse/app/requirements.txt

# 6. Install and Configure the AWS CloudWatch Agent
wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb

# Write CloudWatch Configuration json
cat << 'EOF' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": { "metrics_collection_interval": 10, "run_as_user": "root" },
  "metrics": {
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
    "omit_individual_metric_dimensions": [ "ImageId", "InstanceType" ],
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"], "metrics_collection_interval": 10 }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/opspulse-app.log",
            "log_group_name": "OpsPulse360-Application-Logs",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 7
          }
        ]
      }
    }
  }
}
EOF

# Start the CloudWatch agent daemon
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

# 7. Environment Variables Configuration for Application Context
export DB_HOST="${DB_HOST}"
export DB_NAME="opspulse_db"
export DB_USER="opspulse_admin"
export DB_PASSWORD="${DB_PASSWORD}"
export AWS_REGION="${AWS_REGION}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# 8. Run Streamlit Application Service
nohup python3 -m streamlit run /opt/opspulse/app/app.py --server.port 8000 --server.address 0.0.0.0 > /var/log/opspulse-app.log 2>&1 &

echo "========================================="
echo "SETUP SCRIPT COMPLETED RUNNING"
echo "========================================="