local BasePlugin = require "kong.plugins.base_plugin"
local basic_serializer = require "kong.plugins.log-serializers.basic"
local statsd_logger = require "kong.plugins.datadog.statsd_logger"

local DatadogHandler = BasePlugin:extend()

DatadogHandler.PRIORITY = 1

local ngx_timer_at = ngx.timer.at
local string_gsub = string.gsub
local ipairs = ipairs
local NGX_ERR = ngx.ERR
local ngx_log = ngx.log

local function allow_user_metric(message, identifier)
  if message.consumer ~= nil and
          message.consumer[identifier] ~= nil then
    return true, message.consumer[identifier]
  end
  return false
end

local gauges = {
  gauge = function (stat_name, stat_value, metric_config, logger)
    logger:gauge(stat_name, stat_value, metric_config.sample_rate, metric_config.tags)
  end,
  timer = function (stat_name, stat_value, metric_config, logger)
    logger:timer(stat_name, stat_value, metric_config.tags)
  end,
  counter = function (stat_name, _, metric_config, logger)
    logger:counter(stat_name, 1, metric_config.sample_rate, metric_config.tags)
  end,
  set = function (stat_name, stat_value, metric_config, logger)
    logger:set(stat_name, stat_value, metric_config.tags)
  end,
  histogram = function (stat_name, stat_value, metric_config, logger)
    logger:histogram(stat_name, stat_value, metric_config.tags)
  end,
  meter = function (stat_name, stat_value, metric_config, logger)
    logger:meter(stat_name, stat_value, metric_config.tags)
  end,
  status_count = function (api_name, message, metric_config, logger)
    local stat = api_name..".request.status."..message.response.status
    local total_count = api_name..".request.status.total"
    local sample_rate = metric_config.sample_rate
    logger:counter(stat, 1, sample_rate, metric_config.tags)
    logger:counter(total_count, 1, sample_rate, metric_config.tags)
  end,
  unique_users = function (api_name, message, metric_config, logger)
    local identifier = metric_config.consumer_identifier
    local allow_metric, cust_id = allow_user_metric(message, identifier)
    if allow_metric then
      local stat = api_name..".user.uniques"
      logger:set(stat, cust_id, metric_config.tags)
    end
  end,
  request_per_user = function (api_name, message, metric_config, logger)
    local identifier = metric_config.consumer_identifier
    local allow_metric, cust_id = allow_user_metric(message, identifier)
    if allow_metric then
      local sample_rate = metric_config.sample_rate
      local stat = api_name..".user."..string_gsub(cust_id, "-", "_")
              ..".request.count"
      logger:counter(stat, 1, sample_rate, metric_config.tags)
    end
  end,
  status_count_per_user = function (api_name, message, metric_config, logger)
    local identifier = metric_config.consumer_identifier
    local allow_metric, cust_id = allow_user_metric(message, identifier)
    if allow_metric then
      local stat = api_name..".user."..string_gsub(cust_id, "-", "_")
              ..".request.status."..message.response.status
      local total_count = api_name..".user."..string_gsub(cust_id, "-", "_")
              ..".request.status.total"
      local sample_rate = metric_config.sample_rate
      logger:counter(stat, 1, sample_rate, metric_config.tags)
      logger:counter(total_count, 1, sample_rate, metric_config.tags)
    end
  end
}

local function log(premature, conf, message)
  if premature then return end

  local api_name = string_gsub(message.api.name, "%.", "_")

  local stat_name = {
    request_size = api_name..".request.size",
    response_size = api_name..".response.size",
    latency = api_name..".latency",
    upstream_latency = api_name..".upstream_latency",
    kong_latency = api_name..".kong_latency",
    request_count = api_name..".request.count"
  }

  local stat_value = {
    request_size = message.request.size,
    response_size = message.response.size,
    latency = message.latencies.request,
    upstream_latency = message.latencies.proxy,
    kong_latency = message.latencies.kong,
    request_count = 1
  }

  local logger, err = statsd_logger:new(conf)

  if err then
    ngx_log(NGX_ERR, "failed to create Statsd logger: ", err)
    return
  end
  for _, metric_config in ipairs(conf.metrics) do
    if metric_config.name ~= "status_count"
            and metric_config.name ~= "unique_users"
            and metric_config.name ~= "request_per_user"
            and metric_config.name ~= "status_count_per_user" then
      local stat_name = stat_name[metric_config.name]
      local stat_value = stat_value[metric_config.name]
      local gauge = gauges[metric_config.stat_type]
      if stat_name ~= nil and gauge ~= nil and stat_value ~= nil then
        gauge(stat_name, stat_value, metric_config, logger)
      end

    else
      local gauge = gauges[metric_config.name]
      if gauge ~= nil then
        gauge(api_name, message, metric_config, logger)
      end
    end
  end

  logger:close_socket()
end

function DatadogHandler:new()
  DatadogHandler.super.new(self, "datadog")
end

function DatadogHandler:log(conf)
  DatadogHandler.super.log(self)
  local message = basic_serializer.serialize(ngx)

  local ok, err = ngx_timer_at(0, log, conf, message)
  if not ok then
    ngx_log(NGX_ERR, "failed to create timer: ", err)
  end
end

return DatadogHandler
