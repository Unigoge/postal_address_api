local cjson = require "cjson"
local pretty_json = require "JSON";

local utils = require "utils";
local postal_address_api_handler = require "postal_address_api_handler";

local tests_results = {};

local libpostal = require "postal";

-- Test 1 - libpostal parse() 

local ok, parsed = pcall( libpostal.parse_address, "424 South Maple Ave. Basking Ridge New Jersey", { languages = { "en" }, country = "us" } );
if ok then
    tests_results[ #tests_results + 1 ] = { ["Test 1 - libpostal parse"] = { ["status"] = "ok", ["input"] = "424 South Maple Ave. Basking Ridge New Jersey", ["output"] = parsed } };
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
    tests_results[ #tests_results + 1 ] = { ["Test 2 - libpostal expand"] = { ["status"] = "ok", ["input"] = "119 w 24th street, New York, NY", ["output"] = expanded_results } };
else
    tests_results[ #tests_results + 1 ] = { ["Test 2 - libpostal expand"] = { ["status"] = "failed" } };
end

-- Test 3 - API handler process_address_lookup_request( params ) 

local ok, response, http_status = pcall( postal_address_api_handler.process_address_lookup_request, { ["address"] = "119 w 24th street, New York, NY", ["language"] = "en", ["country"] = "us" } );
if ok then
    tests_results[ #tests_results + 1 ] = { ["Test 3 - handler process_address_lookup_request"] = { 
                                                                              ["status"] = "ok", 
                                                                              ["input"] = { ["address"] = "119 w 24th street, New York, NY", ["language"] = "en", ["country"] = "us" }, 
                                                                              ["output"] = response,
                                                                              ["http_status"] = http_status
                                                                            } };
else
    tests_results[ #tests_results + 1 ] = { ["Test 3 - handler process_address_lookup_request"] = { ["status"] = "failed", ["error"] = response } };
end

return tests_results;
