local cjson = require "cjson"
local pretty_json = require "JSON";

local utils = require "utils";

local _tests = {
    _VERSION = '0.01',
}

local mt = { __index = _tests }

function _tests.run() 

    local postal_address_api_handler = require "postal_address_api_handler";
    
    local tests_results = {};
    
    local libpostal = require "postal";
    
    -- Test 1 - libpostal parse() 
    
    local ok, parsed = pcall( libpostal.parse_address, "424 South Maple Ave. Basking Ridge New Jersey", { languages = { "en" }, country = "us" } );
    if ok then
        local status = "ok";
        if not parsed.road or parsed.road ~= "south maple ave." then
            status = "failed";
        end
        tests_results[ #tests_results + 1 ] = { ["Test 1 - libpostal parse"] = { ["status"] = status, ["input"] = "424 South Maple Ave. Basking Ridge New Jersey", ["output"] = parsed } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 1 - libpostal parse"] = { ["status"] = "failed" } };
    end
    
    -- Test 2 - libpostal expand() 
    
    local ok, expanded_iterator = pcall( libpostal.expand_address, "119 w 24th street, New York, NY", { languages = { "en" } } );
    if ok then
        local expanded_results = {};
        local result = expanded_iterator();
        while result do
            expanded_results[ #expanded_results + 1 ] = result;
            result = expanded_iterator();
        end
        local status = "ok";
        if not string.find( utils.serializeTable( expanded_results ), "119 west 24 street new york ny" ) then
            status = "failed";
        end 
        tests_results[ #tests_results + 1 ] = { ["Test 2 - libpostal expand"] = { ["status"] = status, ["input"] = "119 w 24th street, New York, NY", ["output"] = expanded_results } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 2 - libpostal expand"] = { ["status"] = "failed" } };
    end
    
    -- Test 3 - API handler process_address_lookup_request( params ) 
    
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "119 w 24 street, New York, NY", ["language"] = "en", ["country"] = "us" } );
    if ok then
        local status = "ok";
        if not string.find( response, "\"119 west 24 street, new york, ny, 10001\"") then
            status = "failed";
        end
        tests_results[ #tests_results + 1 ] = { ["Test 3 - handler process_address_lookup_request"] = { 
                                                                                  ["status"] = status, 
                                                                                  ["input"] = { ["address"] = "119 w 24 street, New York, NY", ["language"] = "en", ["country"] = "us" }, 
                                                                                  ["output"] = response,
                                                                                  ["http_status"] = http_status
                                                                                } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 3 - handler process_address_lookup_request"] = { ["status"] = "failed", ["error"] = response } };
    end
    
    -- Test 4 - API handler process_address_lookup_request( params ) 
    
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "119w 24th street, NYC, New York", ["language"] = "en", ["country"] = "us" } );
    if ok then
        local status = "ok";
        if not string.find( response, "\"119 west 24 street, new york, ny, 10001\"") then
            status = "failed";
        end
        tests_results[ #tests_results + 1 ] = { ["Test 4 - handler process_address_lookup_request"] = { 
                                                                                  ["status"] = status, 
                                                                                  ["input"] = { ["address"] = "119w 24th street, NYC, New York", ["language"] = "en", ["country"] = "us" }, 
                                                                                  ["output"] = response,
                                                                                  ["http_status"] = http_status
                                                                                } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 4 - handler process_address_lookup_request"] = { ["status"] = "failed", ["error"] = response } };
    end
    
    -- Test 5 - API handler process_address_lookup_request( params ) 
    
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "Nezahualcoyotl 109, Mexico, DF, Mexico", ["language"] = "en", ["country"] = "mx" } );
    if ok then
        local status = "ok";
        if not string.find( response, "CDMX") then
            status = "failed";
        end    
        tests_results[ #tests_results + 1 ] = { ["Test 5 - handler process_address_lookup_request"] = { 
                                                                                  ["status"] = status, 
                                                                                  ["input"] = { ["address"] = "Nezahualcoyotl 109, Mexico, DF, Mexico", ["language"] = "en", ["country"] = "mx" }, 
                                                                                  ["output"] = response,
                                                                                  ["http_status"] = http_status
                                                                                } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 5 - handler process_address_lookup_request"] = { ["status"] = "failed", ["error"] = response } };
    end

    -- Test 6 - API handler process_address_lookup_request( params ) 
    
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "Nezahualcoyotl 109, Mexico, Mexico", ["language"] = "en", ["country"] = "mx" } );
    if ok then
        local status = "ok";
        if not string.find( response, "CDMX") then
            status = "failed";
        end    
        tests_results[ #tests_results + 1 ] = { ["Test 6 - handler process_address_lookup_request"] = { 
                                                                                  ["status"] = status, 
                                                                                  ["input"] = { ["address"] = "Nezahualcoyotl 109, Mexico, Mexico", ["language"] = "en", ["country"] = "mx" }, 
                                                                                  ["output"] = response,
                                                                                  ["http_status"] = http_status
                                                                                } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 6 - handler process_address_lookup_request"] = { ["status"] = "failed", ["error"] = response } };
    end

    -- Test 7 - API handler process_address_insert_request( params ) 
    
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_insert_request, { ["address"] = "119 west 24th street, New York, NY 10001", ["language"] = "en", ["country"] = "us" } );
    if ok then
        local status = "ok";
        if not string.find( response, "\"address\": \"119 west 24 street, new york, ny, 10001\"") then
            status = "failed";
        end
        if http_status ~= 201 then
            status = "failed";
        end
        tests_results[ #tests_results + 1 ] = { ["Test 7 - handler process_address_insert_request"] = { 
                                                                                  ["status"] = status, 
                                                                                  ["input"] = { ["address"] = "119 west 24th street, New York, NY 10001", ["language"] = "en", ["country"] = "us" }, 
                                                                                  ["output"] = response,
                                                                                  ["http_status"] = http_status
                                                                                } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 7 - handler process_address_insert_request"] = { ["status"] = "failed", ["error"] = response } };
    end

    -- Test 8 - API handler process_address_lookup_request( params ) - exists in key/value store 
    
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "119w 24 street, NYC, New York", ["language"] = "en", ["country"] = "us" } );
    if ok then
        local status = "ok";
        if not string.find( response, "\"address\": \"119 west 24 street, new york, ny, 10001\"") then
            status = "failed";
        end
        if not string.find( response, "\"lat\": 40.") then
            status = "failed";
        end
        if http_status ~= 200 then
            status = "failed";
        end
        tests_results[ #tests_results + 1 ] = { ["Test 8 - handler process_address_lookup_request - address exists in key/value store"] = { 
                                                                                  ["status"] = status, 
                                                                                  ["input"] = { ["address"] = "119w 24 street, NYC, New York", ["language"] = "en", ["country"] = "us" }, 
                                                                                  ["output"] = response,
                                                                                  ["http_status"] = http_status
                                                                                } };
    else
        tests_results[ #tests_results + 1 ] = { ["Test 8 - handler process_address_lookup_request - address exists in key/value store"] = { ["status"] = "failed", ["error"] = response } };
    end

    -- Test 9 - API handler process_address_lookup_request( params ) - well known place 
    local ok, response, http_status = pcall( postal_address_api_handler.process_address_insert_request, { ["address"] = "Empire State Building, New York, NY 10118", ["language"] = "en", ["country"] = "us" } );
    if ok then
        ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "Empire State Building, New York", ["language"] = "en", ["country"] = "us" } );
        local status = "ok";
        if not string.find( response, "\"address\": \"empire state building, new york, ny, 10118 us\"") then
            status = "failed";
        end
        if not string.find( response, "\"lat\": 40.") then
            status = "failed";
        end
        if http_status ~= 200 then
            status = "failed";
        end
        if ok then
            tests_results[ #tests_results + 1 ] = { ["Test 9 - handler process_address_lookup_request - well know place"] = { 
                                                                                      ["status"] = "ok", 
                                                                                      ["input"] = { ["address"] = "Empire State Bulding, New York", ["language"] = "en", ["country"] = "us" }, 
                                                                                      ["output"] = response,
                                                                                      ["http_status"] = http_status
                                                                                    } };
        else
            tests_results[ #tests_results + 1 ] = { ["Test 9 - handler process_address_lookup_request - well known place"] = { ["status"] = "failed", ["error"] = response } };
        end
    else
        tests_results[ #tests_results + 1 ] = { ["Test 9 - handler process_address_insert_request"] = { ["status"] = "failed", ["error"] = response } };
    end
            
    return tests_results;
    
end

return _tests;
