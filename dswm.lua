-- Define our set of hostnames we're going to process just to make sure we don't overload otel backend.
local allowed_values = {
    ["test.hostname.net"] = true,
    ["test2.hostname.net"] = true,
    ["www.example.com"] = true
}

-- for whatever reason we're stripping / from the path, let's fix that.
function normalize_path(tag, timestamp, record)
    local path = record["reqPath"]

    if path == "-" then
        record["reqPath"] = "/"
    elseif path ~= nil and path ~= "" and path:sub(1, 1) ~= "/" then
        record["reqPath"] = "/" .. path
    end

    -- Remove trailing slash if present (except for root path "/")
    if record["reqPath"] ~= "/" and record["reqPath"]:sub(-1) == "/" then
        record["reqPath"] = record["reqPath"]:sub(1, -2)
    end

    return 1, timestamp, record
end

-- our lua script to filter on hostnames we would like to process
function filter_on_hostname(tag, timestamp, record)
    local field_value = record["reqHost"]

    -- Check if the field exists and is in the allowed set
    -- using a set for faster lookups, no need to go over a list
    if field_value and allowed_values[field_value] then
        return 1, timestamp, record 
    end

    return -1, 0, nil  -- Drop the record, not going to process this one.
end

-- a function to convert anything that looks like a number to a number
function convert_to_numbers(tag, timestamp, record)
    local new_record = {}
    
    for key, value in pairs(record) do
        -- Check if the value is a string that looks like a number
        if type(value) == "string" and tonumber(value) then
            new_record[key] = tonumber(value)  -- Convert to number
        else
            new_record[key] = value  -- Keep original value
        end
    end

    return 1, timestamp, new_record
end

-- set otel severity number based on http status code
-- https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
function set_severity_number(tag, timestamp, record)
    local field_to_check = "statusCode"   
    local status_field = "severity_number" -- loki specific field name

    if record[field_to_check] then
        local value = tonumber(record[field_to_check])  -- Convert to number

        -- check http status code
        if value and value >= 400 and value < 500 then
            record[status_field] = 13 -- WARN
        elseif value >= 500 and value < 600 then
            record[status_field] = 17 -- ERROR
        else
            record[status_field] = 9 -- INFO
        end
    else
        record[status_field] = 17  -- set to error if not set
    end

    return 1, timestamp, record
end

-- set otel severity number based on http status code
-- https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
function set_log_level(tag, timestamp, record)
    local field_to_check = "statusCode"   
    local status_field = "level" 

    if record[field_to_check] then
        local value = tonumber(record[field_to_check])  -- Convert to number

        -- check http status code
        if value and value >= 400 and value < 500 then
            record[status_field] = "warn" -- WARN
        elseif value >= 500 and value < 600 then
            record[status_field] = "error" -- ERROR
        else
            record[status_field] = "info" -- INFO
        end
    else
        record[status_field] = "error"  -- set to error if not set
    end

    return 1, timestamp, record
end

-- just for fun, set timestamp based on reqTimeSec
function convert_time(tag, timestamp, record)
    local time_field = "reqTimeSec"        -- The field containing epoch time in seconds
    local output_field = "timestamp"       -- New field for human-readable time

    if record[time_field] then
        local epoch_sec = tonumber(record[time_field])
        if epoch_sec then
            local formatted_time = os.date("%Y-%m-%d %H:%M:%S", epoch_sec)  -- Format time
            record[output_field] = formatted_time  -- Add formatted time to record
        else
            record[output_field] = "INVALID_TIME"
        end
    else
        record[output_field] = "MISSING_TIME"
    end

    return 1, timestamp, record
end

-- set TIMESTAMP of our event based on reqTimeSec from our MESSAGE
function set_timestamp(tag, timestamp, record)
    local new_ts = record["reqTimeSec"]
    if new_ts then
        return 1, new_ts, record
    end
    return 1, timestamp, record
end

-- get grn from customField if it's set
function extract_grn(tag, timestamp, record)
    local custom_field = record["customField"]
    if custom_field then
        -- Extract the value after "grn:"
        local grn_value = custom_field:match("grn:([%x%.]*)")
        if grn_value then
            record["grn"] = grn_value
        end
    end
    return 1, timestamp, record
end


-- span_ids set by random hex functionality in Akamai delivery config
-- we might want to change span_id to req_id if we're also logging midgress so we have multiple e
function extract_otel_ids(tag, timestamp, record)
    local custom_field = record["customField"]
    if custom_field then
        local trace_id_value = custom_field:match("traceId:([%x]*)")
        if trace_id_value then
            record["trace_id"] = trace_id_value
        end
        local span_id_value = custom_field:match("spanId:([%x]*)")
        if span_id_value then
            record["span_id"] = span_id_value
        end
        local parent_id_value = custom_field:match("parentId:([%x]*)")
        if parent_id_value then
            record["parent_id"] = parent_id_value
        end

    end
    return 1, timestamp, record
end

function transform_to_otel_trace(tag, timestamp, record)
    local trace = {
        resourceSpans = {
            {
                resource = {
                    attributes = {
                        { key = "service.name", value = { stringValue = "my_service" } }
                    }
                },
                scopeSpans = {
                    {
                        spans = {
                            {
                                traceId = "",  -- Replace with actual Trace ID
                                spanId = "",  -- Replace with actual Span ID
                                name = record["reqHost"] or "default_span",
                                startTimeUnixNano = timestamp * 1000000000, -- Convert to nanoseconds
                                endTimeUnixNano = (timestamp + 1) * 1000000000, -- Dummy end time
                                attributes = {
                                    { key = "log.level", value = { stringValue = record["reqHost"] or "info" } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return 1, timestamp, trace
end

-- urldecode data
function urldecode(str)
    str = str:gsub('%%(%x%x)', function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return str
end

-- create a valid trace_id from grn
function format_grn_to_trace_id(input_str)
    -- Extract only hexadecimal characters using %x (matches 0-9, a-f, A-F)
    local hex_str = input_str:gsub("[^%x]", "")

    -- Left-pad with zeros if shorter than 32 characters
    -- https://www.w3.org/TR/trace-context/#interoperating-with-existing-systems-which-use-shorter-identifiers
    return string.rep("0", 32 - #hex_str) .. hex_str:sub(-32)
end

function extend_decimal(tag, timestamp, record)
    if record["reqTimeSec"] then
        -- Convert string to number
        local num = tonumber(record["reqTimeSec"])
        if num then
            -- Format it with 9 decimal places (nano seconds)
            record["reqTimeSec"] = string.format("%.9f", num)
        end
    end
    return 1, timestamp, record
end

function to_zipkin_format(tag, timestamp, record)
    local new_record = {
        {
            id = record["span_id"],
            traceId = record["trace_id"],
            parentId = record["parent_id"],
            name = record["reqMethod"] .. " " .. record["reqPath"],
            timestamp =  record["reqTimeSec"] * 1000000, -- this will automatically convert it to microseconds. number
            duration = record["downloadTime"] * 1000, -- convert to microseconds
            kind = "CLIENT",
            localEndpoint = {
                serviceName = record["reqHost"],
                ipv4 = record["edgeIP"],
                port = tonumber(record["reqPort"])
            },
            remoteEndpoint = {
                serviceName = "Gravitee backend", -- could be changed to origin hostname
                ipv4 = record["originIP"],
                port = tonumber(record["reqPort"])
            },
            tags = {
                ["http.method"] = record["reqMethod"],
                ["http.path"] = record["reqPath"],
                ["http.status"] = record["statusCode"],
                ["http.size"] = record["objSize"],
                ["akamai.grn"] = record["grn"],
                ["postnl.environment"] = "akamai-tst",
                ["postnl.contact"] = "joran"
            }
        }
    }
    return 1, timestamp, new_record
end

-- extra origin ip address from breadcrumb data
function extract_a_where_c_o(tag, timestamp, record)
    local breadcrumbs = record["breadcrumbs"]
    if breadcrumbs == nil then
        return 0, 0, record
    end

    -- URL decode breadcrumbs, just in case.
    breadcrumbs = urldecode(breadcrumbs)

    -- Match the last block inside the square brackets and get address.
    local last_bc_block = string.match(breadcrumbs, "%[([^%[]*c=o[^%[]*)%]$")
    record["originIP"] = string.match(last_bc_block, "a=([^,]+)") or "Served directly by Akamai Edge Server"
    
    return 1, timestamp, record
end

-- get origin_rtt from breadcrumb data
-- Extract and return l + k for top-level c=o part
-- l being rtt k the request end time
function get_origin_rtt(breadcrumb)
    if not breadcrumb or type(breadcrumb) ~= "string" then
        return 0
    end

    local decoded = urldecode(breadcrumb)
    local cleaned_input = decoded:gsub("j=%[%[.-%]%],?", "")

    for part in cleaned_input:gmatch("%[(.-)%]") do
        local c = part:match("c=(%a)")
        if c == "o" then
            local l = tonumber(part:match("l=(%d+)") or "0")
            local k = tonumber(part:match("k=(%d+)") or "0")
            return l + k
        end
    end

    return 0
end

-- generate an resource span using information from datastream 
function generate_resource_span(tag, timestamp, record)
    
    local resourceSpan = {}
    
    -- Resource Attributes
    resourceSpan["resource"] = {}
    resourceSpan["resource"]["attributes"] = {}
    table.insert(resourceSpan["resource"]["attributes"], {
        key = "service.name",
        value = { stringValue = "Akamai - Gravitee" }
    })
    
    -- Adding scopeSpans
    resourceSpan["scopeSpans"] = {}
    local scopeSpans = {}
    
    -- Scope
    scopeSpans["scope"] = { name = "Akamai Datastream - " .. record["streamId"]  }
    
    -- Spans
    scopeSpans["spans"] = {}
    local spans = {}
    local span = {}
    
    -- Span Fields
    span["traceId"] = record["trace_id"]
    span["spanId"] = record["span_id"]
    span["parentSpanId"] = record["parent_id"]
    span["flags"] = 0
    span["name"] = record["reqMethod"] .. " " .. record["reqPath"]
    span["kind"] = 2
    span["startTimeUnixNano"] = msec_to_nsec(record["reqTimeSec"]) -- to nanoseconds
    span["endTimeUnixNano"] = span["startTimeUnixNano"] + msec_to_nsec(record["downloadTime"])
        
    -- Span Attributes
    span["attributes"] = {}
    table.insert(span["attributes"], { key = "akamai.reqTimeSec", value = { stringValue = record["reqTimeSec"] } })
    table.insert(span["attributes"], { key = "http.request.method", value = { stringValue = record["reqMethod"] } })
    table.insert(span["attributes"], { key = "server.address", value = { stringValue = record["reqHost"] } })
    table.insert(span["attributes"], { key = "client.address", value = { stringValue = record["cliIP"]} })
    table.insert(span["attributes"], { key = "url.path", value = { stringValue = record["reqPath"] } })
    table.insert(span["attributes"], { key = "url.query", value = { stringValue = record["queryStr"] } })
    table.insert(span["attributes"], { key = "http.response.status_code", value = { intValue = tonumber(record["statusCode"]) } })
    table.insert(span["attributes"], { key = "http.response.body.size", value = { intValue = tonumber(record["objSize"]) } })
    table.insert(span["attributes"], { key = "akamai.grn", value = { stringValue = record["grn"] } })
    table.insert(span["attributes"], { key = "akamai.edge_ip", value = { stringValue = record["edgeIP"] } })
    table.insert(span["attributes"], { key = "akamai.cache_status", value = { intValue = tonumber(record["cacheStatus"]) } })
    -- akamai.rtt is turnaround time on first edge minus origin rtt which includes request end time.
    table.insert(span["attributes"], { key = "akamai.origin_rtt", value = { intValue = get_origin_rtt(record["breadcrumbs"]) } })
    table.insert(span["attributes"], { key = "akamai.rtt", value = { intValue = tonumber(record["turnAroundTimeMSec"] or "0") - get_origin_rtt(record["breadcrumbs"]) } })
    
    
    --table.insert(span["attributes"], { key = "akamai.download_time", value = { intValue = tonumber(record["downloadTime"]) } })

    -- Span Events filled with some timers without any attributes. 
    -- Only add event names that are calculated from start time, so don't add turnAroundTimeMSec for example as that's started after reqEndTimeMSec
    -- possible options: tlsOverheadTimeMSec, reqEndTimeMSec, timeToFirstByte, transferTimeMSec, downloadTime
    span["events"] = {}
    local eventNames = {"tlsOverheadTimeMSec", "reqEndTimeMSec", "timeToFirstByte", "transferTimeMSec", "downloadTime"}

    for _, event in ipairs(eventNames) do
        -- when record is not set, datastream will make it a -
        if record[event] and record[event] ~= "-" then
            table.insert(span["events"], { time_unix_nano = span.startTimeUnixNano + msec_to_nsec(record[event]), name = event })
        end
    end

    -- set span status.code to 2 (Error), unset otherwise. This is the default for server spans
    -- also add this error to the span events.
    if record["statusCode"] ~= nil and tonumber(record["statusCode"]) >= 500 then
        span["status"] = { code = 2 }
        
        local event_attributes = {
            {
                key = "error.code",
                value = { intValue = tonumber(record["statusCode"] or 500) }
            },
            {
                key = "error.message",
                value = { stringValue = record["errorCode"] }
            }
        }
        
        table.insert(span["events"], {time_unix_nano = span["endTimeUnixNano"], name = "error", attributes = event_attributes})
    end

    -- Add the span to the list
    table.insert(scopeSpans["spans"], span)
    
    -- Add scopeSpans to resourceSpans
    table.insert(resourceSpan["scopeSpans"], scopeSpans)
    
    -- Return the generated JSON with 1, timestamp, and record
    return 1, timestamp, resourceSpan
end

function msec_to_nsec(milliseconds)
    return milliseconds * 1000000
end

log_buffer = {}  -- Table to store logs
last_flush = os.time()  -- Track last flush time
flush_interval = 1 -- flush after every second

function collect_traces(tag, timestamp, record)
    -- store our received record in a buffer
    table.insert(log_buffer, record)  

    -- Check if we should flush the buffer
    local current_time = os.time()
    if (current_time - last_flush) >= flush_interval then
        -- Wrap the buffered records into the resourceSpans structure
        local batch = {
            schemaUrl = "https://opentelemetry.io/schemas/1.4.0",
            resourceSpans = log_buffer  -- Directly insert the buffered records into resourceSpans
        }

        -- Clear the buffer after batching
        log_buffer = {}
        last_flush = current_time

        -- forward our modified log to the next step
        return 1, timestamp, batch
    else
        -- stop processing this record, it's stored in the buffer
        return -1, timestamp, record
    end
end