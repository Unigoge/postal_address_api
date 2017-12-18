local cjson = require "cjson"
local pretty_json = require "JSON";

local utils = require "utils";
local postal_address_api_router = require "postal_address_api_router";

local postal = require("postal");

if ngx.worker.id() == 0 then
    ngx.log( ngx.INFO, "Starting Postal API - running tests." );
    
     local ok, err = "unknown";
     ok, err = ngx.timer.at( 0, function() -- need to run from timer context to enable Nginx sockets
     
        local tests = require "postal_address_api_tests";
        local tests_results = tests.run();
        
        ngx.log( ngx.INFO, "Postal API - finished running tests." );
        
        local test_result;
        for _, test_result in ipairs( tests_results ) do 
            ngx.log( ngx.INFO, "Postal API - test result: ", utils.serializeTable( test_result ) );
        end
     end );
     if not ok then
        ngx.log( ngx.ERR, "Postal API - unable to start tests - error: ", err );
     end    
end

