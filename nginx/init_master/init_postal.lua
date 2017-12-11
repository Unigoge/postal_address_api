
local postal = require("postal");

function serializeTable(val, name, skipnewlines, depth)
          skipnewlines = skipnewlines or false
          depth = depth or 0
      
          local tmp = string.rep(" ", depth)
      
          if name then tmp = tmp .. name .. " = " end
      
          if type(val) == "table" then
              tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")
      
              for k, v in pairs(val) do
                  tmp =  tmp .. serializeTable(v, k, skipnewlines, depth + 1) .. "," .. (not skipnewlines and "\n" or "")
              end
      
              tmp = tmp .. string.rep(" ", depth) .. "}"
          elseif type(val) == "number" then
              tmp = tmp .. tostring(val)
          elseif type(val) == "string" then
              tmp = tmp .. string.format("%q", val)
          elseif type(val) == "boolean" then
              tmp = tmp .. (val and "true" or "false")
          else
              tmp = tmp .. "\"[inserializeable datatype:" .. type(val) .. "]\""
          end
      
          return tmp
end

local ok, error = pcall( postal.setup );
if not ok then
	ngx.log( ngx.ERR, "Unable to setup libpostal: ", error );
end

-- Tests

local ok, expanded_results = pcall( postal.expand_address, "424 South Maple Ave. Basking Ridge Alberta" );
if ok and type( expanded_results ) == "function" then
	local result = expanded_results();
	while result do
		ngx.log( ngx.INFO, "Test 1: ", result );
                local ok, parsed = pcall( postal.parse_address, result, { languages = { "en" }, country = "ca" } );
                if ok then
                         ngx.log( ngx.INFO, "Test 1:\n", serializeTable( parsed ) );
                end

		result = expanded_results();
	end
else
	ngx.log( ngx.ERR, "Test 1: ", expanded_results );
end

ok, expanded_results = pcall( postal.expand_address, "119 w 24th st, New York, NY", { languages = { "en" } } );
if ok and type( expanded_results ) == "function" then
        local result = expanded_results();
        while result do
                ngx.log( ngx.INFO, "Test 2: ", result );
                result = expanded_results();
        end
else
        ngx.log( ngx.ERR, "Test 2: ", expanded_results );
end

ok, expanded_results = pcall( postal.expand_address, "119 w 24th str, New York, NY", { languages = { "en" }, expand_numex = true } );
if ok and type( expanded_results ) == "function" then
        local result = expanded_results();
        while result do
                ngx.log( ngx.INFO, "Test 2.1: ", result );
                result = expanded_results();
        end
else
        ngx.log( ngx.ERR, "Test 2.1: ", expanded_results );
end

ok, expanded_results = pcall( postal.expand_address, "119w 24th st New York, NY", { languages = { "en" } } );
if ok and type( expanded_results ) == "function" then
        local result = expanded_results();
        while result do
                ngx.log( ngx.INFO, "Test 3: ", result );
                result = expanded_results();
        end
else
        ngx.log( ngx.ERR, "Test 3: ", expanded_results );
end

ok, expanded_results = pcall( postal.expand_address, "World Trade Center 119 w 24th str #46a, Manhattan New York, NY", { languages = { "en" } } );
if ok and type( expanded_results ) == "function" then
        local result = expanded_results();
        while result do
                ngx.log( ngx.INFO, "Test 4: ", result );
		local ok, parsed = pcall( postal.parse_address, result, { languages = { "en" }, country = "us" } );
		if ok then
			 ngx.log( ngx.INFO, "Test 4:\n", serializeTable( parsed ) );
		end
                result = expanded_results();
        end
else
        ngx.log( ngx.ERR, "Test 4: ", expanded_results );
end

ok, results = pcall( postal.parse_address, "119 w24th str New York, NY", { languages = { "en" }, country = "us" } );
if ok and type( expanded_results ) == "function" then
	ngx.log( ngx.INFO, "Test 5:\n", serializeTable( results ) );
else
        ngx.log( ngx.ERR, "Test 5: ", results );
end

