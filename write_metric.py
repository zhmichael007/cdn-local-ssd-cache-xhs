from google.cloud import bigquery
from google.cloud import monitoring_v3
import datetime
import time
import os
import argparse

# Construct a BigQuery client object.
client = bigquery.Client()
now = datetime.datetime.now()
delta = datetime.timedelta(minutes=1)
start = now - delta - delta
end = now - delta
start_time = start.strftime("%Y-%m-%d %H:%M:00 UTC")
end_time = end.strftime("%Y-%m-%d %H:%M:00 UTC")
print(start_time)
print(end_time)

query = """
select sum(httpRequest.responseSize) /1024/1024/60 as bandwidth
from
`cdn-for-xhs.nginx_access_log.nginx_access`
where
jsonPayload.httprequest.upstreamaddr != ""
and jsonPayload.httprequest.upstreamaddr NOT LIKE '10.%' 
and 
"""
query = query + "timestamp >= \"" + start_time + "\" and timestamp < \"" + end_time + "\""
#print(query)

query_job = client.query(query) # Make an API request.
#print("The query data:")

for row in query_job:
    # Row values can be accessed by field name or index.
    bandwidth = row["bandwidth"]
    if bandwidth is None:
        bandwidth = 0

bandwith = round(bandwidth,2)
print("The query data: %.2f" % (bandwidth))

project_id = "cdn-for-xhs"
client = monitoring_v3.MetricServiceClient()
project_name = f"projects/{project_id}"

series = monitoring_v3.TimeSeries()
series.metric.type='custom.googleapis.com/nginx_upstream_bandwidth'
series.resource.type = 'global'

now = time.time()
seconds = int(now)
nanos = int((now - seconds) * 10 ** 9)
interval = monitoring_v3.TimeInterval(
    {"end_time": {"seconds": seconds, "nanos": nanos}}
)

point = monitoring_v3.Point({"interval": interval, "value": {"double_value": bandwidth}})
series.points = [point]
client.create_time_series(name=project_name, time_series=[series])
