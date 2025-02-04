local config = require "config"
local time = require "time"
local cjson = require "cjson.safe"
local stringutf8 = require "stringutf8"
local loggerFactory = require "loggerFactory"

local upper = string.upper
local concat = table.concat

local ATTACK_PREFIX = "attack_"
local ATTACK_TYPE_PREFIX = "attack_type_"

local logPath = config.get("logPath")
local rulePath = config.get("rulePath")

local function writeAttackLog()
    if config.isAttackLogOn then
        local ruleTable = ngx.ctx.ruleTable
        local data = ngx.ctx.hitData
        local action = ngx.ctx.action
        local rule = ruleTable.rule
        local ruleType = ruleTable.ruleType

        local realIp = ngx.ctx.ip
        local country = ngx.ctx.geoip.country
        local province = ngx.ctx.geoip.province
        local city = ngx.ctx.geoip.city
        local method = ngx.req.get_method()
        local url = ngx.var.request_uri
        local ua = ngx.ctx.ua
        local host = ngx.var.server_name
        local protocol = ngx.var.server_protocol
        local attackTime = ngx.localtime()

        if config.isJsonFormatLogOn then
            local logTable = {
                attack_type = ruleType,
                remote_addr = realIp,
                geoip_country = country,
                geoip_province = province,
                geoip_city = city,
                attack_time = attackTime,
                http_method = method,
                server = host,
                request_uri = url,
                request_protocol = protocol,
                request_data = data or '',
                user_agent = ua,
                hit_rule = rule,
                action = action
            }
            local logStr, err = cjson.encode(logTable)
            if logStr then
                local hostLogger = loggerFactory.getLogger(logPath, host, true)
                hostLogger:log(logStr .. '\n')
            else
                ngx.log(ngx.ERR, "failed to encode json: ", err)
            end
        else
            local address = country .. province .. city
            address = stringutf8.defaultIfBlank(address, '-')
            ua = stringutf8.defaultIfBlank(ua, '-')
            data = stringutf8.defaultIfBlank(data, '-')

            local logStr = concat({ruleType, realIp, address, "[" .. attackTime .. "]", '"' .. method, host, url, protocol .. '"', data, '"' .. ua .. '"', '"' .. rule .. '"', action},' ')
            local hostLogger = loggerFactory.getLogger(logPath, host, true)
            hostLogger:log(logStr .. '\n')
        end
    end
end

local function writeIPBlockLog()
    local ruleTable = ngx.ctx.ruleTable
    local ip = ngx.ctx.ip
    local hostLogger = loggerFactory.getLogger(logPath .. "ipBlock.log", 'ipBlock', false)
    hostLogger:log(concat({ngx.localtime(), ip, ruleTable.ruleType, ruleTable.ipBlockTimeout .. 's'}, ' ') .. "\n")

    if ruleTable.ipBlockTimeout == 0 then
        local ipBlackLogger = loggerFactory.getLogger(rulePath .. "ipBlackList", 'ipBlack', false)
        ipBlackLogger:log(ip .. "\n")
    end
end

-- 按小时统计当天请求流量，存入缓存，key格式：2023-05-05 09
local function countRequestTraffic()
    local hour = time.getDateHour()
    local dict = ngx.shared.dict_req_count
    local expireTime = time.getExpireTime()
    local count, err = dict:incr(hour, 1, 0, expireTime)
    if not count then
        dict:set(hour, 1, expireTime)
        ngx.log(ngx.ERR, "failed to count traffic ", err)
    end
end

--[[
    按小时统计当天攻击请求流量，存入缓存，key格式：attack_2023-05-05 09
    按天统计当天所有攻击类型流量，存入缓存，key格式：attack_type_2023-05-05_ARGS
]]
local function countAttackRequestTraffic()
    local ruleTable = ngx.ctx.ruleTable
    local ruleType = upper(ruleTable.ruleType)
    local dict = ngx.shared.dict_req_count
    local count, err = nil, nil
    local expireTime = time.getExpireTime()

    if ruleType ~= 'WHITEIP' then
        local hour = time.getDateHour()
        local key = ATTACK_PREFIX .. hour
        count, err = dict:incr(key, 1, 0, expireTime)
        if not count then
            dict:set(key, 1, expireTime)
            ngx.log(ngx.ERR, "failed to count attack traffic ", err)
        end
    end

    local today = ngx.today() .. '_'
    local typeKey = ATTACK_TYPE_PREFIX .. today .. ruleType
    count, err = dict:incr(typeKey, 1, 0, expireTime)

    if not count and err == "not found" then
        dict:set(typeKey, 1, expireTime)
        ngx.log(ngx.ERR, "failed to count attack traffic ", err)
    end
end

if config.isWAFOn then
    countRequestTraffic()

    local isAttack = ngx.ctx.isAttack
    if isAttack then
        writeAttackLog()
        countAttackRequestTraffic()
    end

    if ngx.ctx.ipBlocked then
        writeIPBlockLog()
    end

end
