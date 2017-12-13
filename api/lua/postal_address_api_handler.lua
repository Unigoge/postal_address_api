local cjson = require "cjson"
local pretty_json = require "JSON";

local utils = require "utils";

local _handler = {
    _VERSION = '0.01',
}

local mt = { __index = _handler }

-- all methods of this class are static
--
-- make_XXXX methods should be executed from Nginx requests processing content only
--

--
-- expects URL that end as "../424+South+Maple+Ave+Basking+Ridge+NJ+07920?language=en&country=us" (could also use %20 for spaces or any other common URL encoding)
-- language and country query parameters are optional
--
function _handler.make_address_lookup_handler()

    return function( params )
    
        if params.request_method ~= "GET" then
            ngx.log( ngx.ERR, "Postal Address API - Wrong request method ", params.request_method );
            return "{ \"error\": \"Postal Address API - unable to process request - wrong HTTP method\" }\n", 400;
        end
    
        if params.address and #params.address > 4 then -- the minimal length of address - like "home"
            params.address = ngx.unescape_uri( params.address);
            params.address = str.gsub( params.address, "+", " " );
        end
        if params.address and #params.address < 4 then
            ngx.log( ngx.ERR, "Postal Address API - address is too short - ", params.address );
            return "{ \"error\": \"Postal Address API - unable to process request - address is too short\" }\n", 400;        
        elseif not params.address then
            ngx.log( ngx.ERR, "Postal Address API - missing address" );
            return "{ \"error\": \"Postal Address API - unable to process request - missing address\" }\n", 400;         
        end
        
        return _handler.process_address_lookup_request( params );
    end
end

--
-- expects JSON body with an array of JSON objects:
-- [
--    { "address": "424 South Maple Ave Basking Ridge NJ 07920", "language": "en", "country": "us" },
--    { "address": "119 w 24th st, New York, NY", "language": "en" },
-- ]
--
-- "language" and "country" attributes are optional
function _handler.make_address_lookup_batch_handler()

    return function( params )

        if params.request_method ~= "POST" then
            ngx.log( ngx.ERR, "Postal Address API - Wrong request method ", params.request_method );
            return "{ \"error\": \"Postal Address API - unable to process request - wrong HTTP method\" }\n", 400;
        end

        local req_body;
        
        params.ngx_req.read_body();
        
        req_body = params.ngx_req.get_body_data();
        if not req_body then
        -- most likely body is too big and was dumped into the file
                local req_body_file_name = ngx.req.get_body_file();
                -- If the file had been buffered, open it, read contents into req_body and close 
                if req_body_file_name then
                    local file = io.open(req_body_file_name);
                    -- TODO: check for file size here?
                    req_body = file:read("*a");
                    file:close();
                end            
        end
        
        if not req_body then
        -- need to create error response and bail out
            ngx.log( ngx.ERR, "Postal Address API -  Request doesn't have body" );      
            return "{ \"error\": \"Postal Address API -  Request doesn't have body\" }\n", 400;
        end
        
        -- parse received JSON
        local ok, request_data_object = pcall( cjson.decode, req_body );
        if ok and type(request_data_object) == "string" then -- in case if user has encoded JSON array as a string
            ok, request_data_object = pcall( cjson.decode, request_data_object );
        end
        if not ok or not request_data_object or type(request_data_object) ~= "table" or not request_data_object[1] then
            ngx.log( ngx.ERR, "Postal Address API - Unable to parse Request's JSON: ", req_body );
            return "{ \"error\": \"Postal Address API - Unable to parse Request's JSON\" }\n", 400;
        end
        
        local response_json_parts = {};
        local idx, address_object;
        for idx, address_object in ipairs( request_data_object ) do
        
            if address_object.address and #address_object.address > 4 then
                params.language = address_object.language;
                params.country = address_object.country;
                params.address = address_object.address;
                
                local http_status;
                response_json_parts[ #response_json_parts + 1 ], http_status = _handler.process_address_lookup_request( params );
                if http_status ~= 200 then
                     ngx.log( ngx.INFO, "Postal Address API - Unable to process address - error: ", response_json_parts[ #response_json_parts ] );
                end
                params.language = nil;
                params.country = nil;
                params.address = nil;
                
            elseif address_object.address then
                response_json_parts[ #response_json_parts + 1 ] = "{ \"error\": \"Postal Address API - unable to process request - address is too short\" }";
            else
                response_json_parts[ #response_json_parts + 1 ] = "{ \"error\": \"Postal Address API - unable to process request - missing address\" }";            
            end            
        end
        
        --need to get rid of the closing ",\n" in string produced by table.concat
        local response_json_str = table.concat( response_json_parts, ",\n" );
        return "[\n" .. str.sub( response_json_str, 1, #response_json_str - 2) .. "\n]\n", 200; -- always returns 200 
    end
end

--
-- expects JSON object with following attributes:
-- {
--    "address": "424 South Maple Ave Basking Ridge NJ 07920",
--    "language": "en", 
--    "country": "us",
--    "lat": 40.6863623,
--    "lng": -74.53439190000002,
-- ]
--
-- "language", "country", "lat", "lng" attributes are optional
--
-- the address is expected to be free of typos and it should include all essential parts and postal code
--
function _handler.make_address_insert_handler()

    return function( params )

        if params.request_method ~= "PUT" then
            ngx.log( ngx.ERR, "Postal Address API - Wrong request method ", params.request_method );
            return "{ \"error\": \"Postal Address API - unable to process request - wrong HTTP method\" }\n", 400;
        end

        local req_body;
        
        params.ngx_req.read_body();
        
        req_body = params.ngx_req.get_body_data();
        if not req_body then
        -- most likely body is too big and was dumped into the file
                local req_body_file_name = ngx.req.get_body_file();
                -- If the file had been buffered, open it, read contents into req_body and close 
                if req_body_file_name then
                    local file = io.open(req_body_file_name);
                    -- TODO: check for file size here?
                    req_body = file:read("*a");
                    file:close();
                end            
        end
        
        if not req_body then
        -- need to create error response and bail out
            ngx.log( ngx.ERR, "Postal Address API -  Request doesn't have body" );      
            return "{ \"error\": \"Postal Address API -  Request doesn't have body\" }\n", 400;
        end
        
        -- parse received JSON
        local ok, request_data_object = pcall( cjson.decode, req_body );
        if ok and type(request_data_object) == "string" then -- in case if user has encoded JSON array as a string
            ok, request_data_object = pcall( cjson.decode, request_data_object );
        end
        if not ok or not request_data_object or type(request_data_object) ~= "table" then
            ngx.log( ngx.ERR, "Postal Address API - Unable to parse Request's JSON: ", req_body );
            return "{ \"error\": \"Postal Address API - Unable to parse Request's JSON\" }\n", 400;
        end
        
        params.request = request_data_object;
        return _handler.process_address_insert_request( params );    
    end
end

--
-- expects URL that end as "../424+South+Maple+Ave+Basking+Ridge+NJ+07920?language=en&country=us" (could also use %20 for spaces or any other common URL encoding)
-- language and country query parameters are optional
--
-- the address is expected to be free of typos and it should include all essential parts and postal code
--
function _handler.make_address_delete_handler()

    return function( params )

        if params.request_method ~= "DELETE" then
            ngx.log( ngx.ERR, "Postal Address API - Wrong request method ", params.request_method );
            return "{ \"error\": \"Postal Address API - unable to process request - wrong HTTP method\" }\n", 400;
        end
    
        if params.address and #params.address > 4 then -- the minimal length of address - like "home"
            params.address = ngx.unescape_uri( params.address);
            params.address = str.gsub( params.address, "+", " " );
        end
        if params.address and #params.address < 4 then
            ngx.log( ngx.ERR, "Postal Address API - address is too short - ", params.address );
            return "{ \"error\": \"Postal Address API - unable to process request - address is too short\" }\n", 400;        
        elseif not params.address then
            ngx.log( ngx.ERR, "Postal Address API - missing address" );
            return "{ \"error\": \"Postal Address API - unable to process request - missing address\" }\n", 400;         
        end
        
        return _handler.process_address_delete_request( params );
    end
end

--
-- the following methods could be invoked outside of Nginx requests processing context - from tests or batch CLI
--

local postal_address_addr_class = require "postal_address_api_addr_class";
local postal_address_places_class = require "postal_address_places_class";

local MAXNUMBEROFTHREADS = 300;
local MAXNUMBEROFTHREADSPERADDRESS = 5;

-- shared by all handlers threads info
local all_threads = {};
local curr_thread_number = 1;
local total_running_threads = 0;

function _handler.process_address_lookup_request( params )

    if not params or type(params) ~= "table" or not params.address then
        ngx.log( ngx.ERR, "Postal Address API - missing address" );
        return "{ \"error\": \"Postal Address API - unable to process request - missing address\" }\n", 400;
    end

    local address_object, error = postal_address_addr_class.get_new_address( params.address, params.language, params.country );
    if not address_object then
        if not error then error = "unknown" end
        ngx.log( ngx.ERR, "Postal Address API - unable to initialize address - error: ", error );
        return "{ \"error\": \"Postal Address API - unable to process request - error: " .. error .. "\" }\n", 500;    
    end
    
    error = address_object:expand_address(); -- this method also does places lookup and sorts address options
    if error then
        ngx.log( ngx.ERR, "Postal Address API - unable to expand address - error: ", error );
        return "{ \"error\": \"Postal Address API - unable to process request - error: " .. error .. "\" }\n", 500;        
    end
    
    -- need to implement asyncronous lookup
    local threads = {};
    local running_threads = 0;
    local option_number = 1;
    while( option_number <= address_object:get_number_of_address_options() ) do
        local address_option = address_object:get_address_option( option_number );
        if not address_option then
            break;
        end
        
        if address_object:is_ready_for_lookup( address_option ) then -- we don't want to spawn unnecessary threads
        
            while total_running_threads + 1 > MAXNUMBEROFTHREADS do
                -- potentialy dangeros - difficult to ensure "fairness" under heavy load
                utils.wait_for_any_thread( all_threads, MAXNUMBEROFTHREADS );
            end
            
            local thread_handle = ngx.thread.spawn( function( address_option, option_number )
                total_running_threads = total_running_threads + 1;
                 
                local ok, error = pcall( address_object.lookup_address_option, address_object, address_option );
                if not ok then
                    ngx.log( ngx.ERR, "Postal Address API - unable to execute address lookup - execution error. " );
                end
                if error then
                    ngx.log( ngx.INFO, "Postal Address API - unable to execute address lookup - error: ", error );
                end
                threads[ tostring( option_number) ] = nil; -- remove thread from waiting set
                total_running_threads = total_running_threads - 1;
            end );
            
            -- add thread to a "all threads" collection
            curr_thread_number = curr_thread_number + 1;
            all_threads[ tostring( curr_thread_number ) ] = thread_handle;
            if curr_thread_number >= MAXNUMBEROFTHREADS + MAXNUMBEROFTHREADS then
                curr_thread_number = 1;
            end
            
            threads[ tostring( option_number) ] = thread_handle;
            running_threads = running_threads + 1;
            if running_threads == MAXNUMBEROFTHREADSPERADDRESS then
                running_threads = utils.wait_for_any_thread( threads );
            end
        end 
    end
    
    utils.wait_for_all_threads( threads );
    
    local results = address_object:get_verified_address();
    if results then
        -- found a correct address with known lat/lng
        return address_object.format_to_json( results ), 200;
    else
        -- not found - return error and include address options
        results = {};
        results["error"] = "Postal Address API - unable to find address";
        
        local address_options = {};
        results["options"] = address_options;
        
        option_number = 1;
        while( option_number <= address_object:get_number_of_address_options() ) do        
            address_options[ #address_options + 1 ] = address_object.format_to_string( address_object:get_address_option( option_number ) );
        end
        
        local response_json = pretty_json:encode_pretty( results );
        if response_json then
            return response_json, 404
        else
            return  "{ \"error\": \"Postal Address API - unable to process request - building response error\" }\n", 500; 
        end
    end
end

function _handler.process_address_insert_request( params )

    if not params or type(params) ~= "table" or not params.address then
        ngx.log( ngx.ERR, "Postal Address API - missing address" );
        return "{ \"error\": \"Postal Address API - unable to process request - missing address\" }\n", 400;
    end

    local address_object, error = postal_address_addr_class.get_new_address( params.address, params.language, params.country );
    if not address_object then
        if not error then error = "unknown" end
        ngx.log( ngx.ERR, "Postal Address API - unable to initialize address - error: ", error );
        return "{ \"error\": \"Postal Address API - unable to process request - error: " .. error .. "\" }\n", 500;    
    end
    
    error = address_object:expand_address(); -- this method also does places lookup and sorts address options
    if error then
        ngx.log( ngx.ERR, "Postal Address API - unable to expand address - error: ", error );
        return "{ \"error\": \"Postal Address API - unable to process request - error: " .. error .. "\" }\n", 500;        
    end
    
    -- going to use the first addres option
    local address_option = address_object:get_address_option( 1 );
    if not params.lat or not params.lng then
        --
        -- going to cheat here - will send request to Google trying to find lat/long
        --
        local encoded_address = address_object.format_to_string( address_option );
        encoded_address = ngx.escape_uri( encoded_address );
        local url = "http://maps.googleapis.com/maps/api/geocode/json?address=" .. encoded_address .. "&sensor=false"
        local google_response, err = utils.send_http_req( url, {
                                          method = "GET",
                                          headers = {
                                            ["Accept"] = "*/*"
                                          } 
                                     } );
        if not google_response then
            ngx.log( ngx.INFO, "Postal Address API - unable to insert address - Google request error: ", err );
        else
            local ok, google_response_object = pcall( cjson.decode, google_response );
            if not ok or not google_response_object or type(google_response_object) ~= "table" then
                ngx.log( ngx.INFO, "Postal Address API - Unable to parse Google JSON" );
            else
                if google_response_object.results and google_response_object.results[1] then
                    google_response_object = google_response_object.results[1];
                end
                if google_response_object.geometry and google_response_object.geometry.location 
                    and google_response_object.geometry.location.lat and google_response_object.geometry.location.lng then
                    
                    params.lat = google_response_object.geometry.location.lat;
                    params.lng = google_response_object.geometry.location.lng;
                end
            end 
        end
    end
    
    if not params.lat or not params.lng then
        ngx.log( ngx.INFO, "Postal Address API - unable to insert address - missing lat/long" );
        return "{ \"error\": \"Postal Address API - unable to insert address - missing lat/long\" }\n", 400;            
    end
    
    error = address_object:insert_address( address_option, params.lat, params.lng );
    if not error then
        return address_object.format_to_json( address_object:get_verified_address() ), 201;
    else
        ngx.log( ngx.ERR, "Postal Address API - unable to insert address - insertion error: ", error );
        return "{ \"error\": \"Postal Address API - unable to insert address - insertion error\" }\n", 500;            
    end
end

function _handler.process_address_delete_request( params )

    if not params or type(params) ~= "table" or not params.address then
        ngx.log( ngx.ERR, "Postal Address API - missing address" );
        return "{ \"error\": \"Postal Address API - unable to process request - missing address\" }\n", 400;
    end

    local address_object, error = postal_address_addr_class.get_new_address( params.address, params.language, params.country );
    if not address_object then
        if not error then error = "unknown" end
        ngx.log( ngx.ERR, "Postal Address API - unable to initialize address - error: ", error );
        return "{ \"error\": \"Postal Address API - unable to process request - error: " .. error .. "\" }\n", 500;    
    end
    
    error = address_object:expand_address(); -- this method also does places lookup and sorts address options
    if error then
        ngx.log( ngx.ERR, "Postal Address API - unable to expand address - error: ", error );
        return "{ \"error\": \"Postal Address API - unable to process request - error: " .. error .. "\" }\n", 500;        
    end
    
    -- going to use the first addres option
    local address_option = address_object:get_address_option( 1 );
    error = address_object:delete_address( address_option );
    if not error then
        return "Deleted.\n", 204; -- no content
    else
        if error == "not found" then
            return "{ \"error\": \"Postal Address API - unable to delete address - not found\" }\n", 404;
        else
            ngx.log( ngx.ERR, "Postal Address API - unable to delete address - error: ", error );
            return "{ \"error\": \"Postal Address API - unable to delete address - deletion error\" }\n", 500;
        end            
    end    
end

return _handler;