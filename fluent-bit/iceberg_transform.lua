-- =============================================================================
-- Iceberg 変換 Lua スクリプト (FireLens カスタムイメージにベイク)
-- custom.conf の [FILTER] Name lua (Match iceberg.*) から呼び出される。
--
-- 役割:
--   parser (otel_json) で展開済みの OTel フィールドを、Iceberg テーブルの
--   小文字フラットスキーマ (design.md / Iceberg_Schema_Mapping) へ変換する。
--   Firehose の Iceberg 配信はレコードのキー名を宛先テーブルのカラム名に
--   一致させる必要があるため、ここでキー名・型を最終形へ整える。
--
--   入力レコード例 (parser 展開後):
--     { timestamp="2026-06-20T12:06:28.004809664Z", severityNumber=17,
--       severityText="ERROR", body="...", resource={...}, attributes={...},
--       container_name="app", ecs_task_arn="...", ... }
--
--   出力レコード (Iceberg カラムのみに置換):
--     { event_time="2026-06-20T12:06:28.004809", severity_number=17,
--       severity_text="ERROR", body="...",
--       resource_json="{...}", attributes_json="{...}",
--       ingest_date="2026-06-20" }
--
-- 注意:
--   - aws-for-fluent-bit の Lua には cjson が含まれないため、ネスト
--     (resource/attributes) の JSON 文字列化は本ファイル内の簡易エンコーダで行う。
--   - event_time は Iceberg の timestamp 列。タイムゾーンなし・マイクロ秒精度の
--     ISO8601 文字列へ整形する (RFC3339Nano の末尾 Z とナノ秒を除去)。
-- =============================================================================

-- 文字列を JSON 用にエスケープする
local function escape_str(s)
    s = string.gsub(s, '\\', '\\\\')
    s = string.gsub(s, '"', '\\"')
    s = string.gsub(s, '\n', '\\n')
    s = string.gsub(s, '\r', '\\r')
    s = string.gsub(s, '\t', '\\t')
    return s
end

-- 任意の Lua 値 (文字列/数値/真偽/テーブル/nil) を JSON 文字列へエンコードする
local function encode(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        -- 整数は小数点なしで出力する
        if v == math.floor(v) and v ~= math.huge and v ~= -math.huge then
            return string.format("%d", v)
        end
        return tostring(v)
    elseif t == "string" then
        return '"' .. escape_str(v) .. '"'
    elseif t == "table" then
        -- 配列かオブジェクトかを判定する
        local n = 0
        local is_array = true
        for k, _ in pairs(v) do
            n = n + 1
            if type(k) ~= "number" then
                is_array = false
            end
        end
        local parts = {}
        if is_array and n > 0 then
            for i = 1, n do
                parts[#parts + 1] = encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do
            parts[#parts + 1] = '"' .. escape_str(tostring(k)) .. '":' .. encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

-- RFC3339Nano (例 2026-06-20T12:06:28.004809664Z) を
-- タイムゾーンなし・マイクロ秒の ISO8601 (2026-06-20T12:06:28.004809) へ整形する
local function to_iceberg_timestamp(s)
    if type(s) ~= "string" then
        return s
    end
    -- 末尾のタイムゾーン (Z もしくは +09:00 等) を除去
    s = string.gsub(s, "Z$", "")
    s = string.gsub(s, "[%+%-]%d%d:%d%d$", "")
    -- 小数秒をマイクロ秒 (6 桁) に丸める
    local base, frac = string.match(s, "^(.-)%.(%d+)$")
    if base ~= nil then
        frac = string.sub(frac .. "000000", 1, 6)
        return base .. "." .. frac
    end
    return s
end

-- Fluent Bit lua フィルタのコールバック
-- 戻り値 2 = タイムスタンプとレコードの両方を置換する
function transform(tag, ts, record)
    local out = {}

    local raw_ts = record["timestamp"]
    out["event_time"]      = to_iceberg_timestamp(raw_ts)
    out["severity_number"] = record["severityNumber"]
    out["severity_text"]   = record["severityText"]
    out["body"]            = record["body"]
    out["resource_json"]   = encode(record["resource"])
    out["attributes_json"] = encode(record["attributes"])

    if type(raw_ts) == "string" and string.len(raw_ts) >= 10 then
        out["ingest_date"] = string.sub(raw_ts, 1, 10)
    end

    return 2, ts, out
end
