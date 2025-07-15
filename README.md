Example on how to convert an Akamai DataStream input into an otel format.

start the otel collector via './otelcol --config otel-collector.yaml'
start fluent-bit via with 'fluent-bit -c fluentbit.yaml'.

Now just dump your datastream example http://localhost:2020/ds.log and off you go.

```
{
  "version": "1",
  "reqTimeSec": "1752595133238",
  "turnAroundTimeMSec": "35",
  "streamId": "1234abc",
  "cacheStatus": "1",
  "edgeIP": "23.50.51.174",
  "serverCountry": "SG",
  "reqId": "1239f220",
  "tlsOverheadTimeMSec": "16",
  "reqEndTimeMSec": "26",
  "reqPath": "-",
  "reqMethod": "POST",
  "reqHost": "test2.hostname.net",
  "statusCode": "403",
  "cliIP": "128.147.28.67",
  "errorCode": "WAF error",
  "totalBytes": "0",
  "objSize": "1208",
  "downloadTime": "1000",
  "queryStr": "param=value",
  "breadcrumbs": "//BC/[a=23.50.55.38,c=g,k=8,l=35,j=[[a=54.73.53.134,c=o,k=2,l=27,m=0]]],[a=54.73.53.134,c=o,k=2,l=27,m=0]",
  "customField": "grn:0.53b3217.1741166436.12e9fda%7cx-akamai-bot-action:none%7cx-client-tls-fingerprint:3%7e5694e70ae5aa84c6%7ctraceId:0cf929f5a169a2356a610121f0287519%7cspanId:388afca56b4bc214"
}
```
