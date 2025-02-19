-- Define our list of hostnames we're going to process
local allowed_values = {
    ["test.hostname.net"] = true,
    ["www.example.com"] = true
}

-- our lua script to filter on hostnames we would like to process
function filter_on_hostname(tag, timestamp, record)
    local field_value = record["reqHost"]

    -- Check if the field exists and is in the allowed set
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

-- set otel severitynumber based on http status code
-- https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
function set_severity_number(tag, timestamp, record)
    local field_to_check = "statusCode"   
    local status_field = "severityNumber" 

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
