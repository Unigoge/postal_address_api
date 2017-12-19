local utils = require "utils";
local postal_address_api_handler = require "postal_address_api_handler";

local _router = {
    _VERSION = '0.01',
}

local mt = { __index = _router }

local router_module = require "router";
local r = router_module.new();

local postal_address_api_root = "/";
local postal_address_api_version = "0.1";

r:match({
  OPTIONS = {
  
      [ "/*any_path" ] = function( params )
          return "\n", 200;
      end
  },
  GET = {
  
      [ "/address_lookup" ] = function( params )
      
        -- TODO probably should redirect to API specification page
        -- ngx.header["Location"] = "https://api-spec-url";
        -- return "https://api-spec-url\n", 301;
        return "{ \"error\": \"Bad request - missing address\" }", 404;
      end,
            
      [ "/address_lookup/*address" ] = postal_address_api_handler.make_address_lookup_handler();
      
  },

  POST = {
  
      [ "/address_lookup" ] = postal_address_api_handler.make_address_lookup_batch_handler();
      
        
  },

  PUT = {

      [ "/address_lookup" ] = function( params )
      
        -- TODO probably should redirect to API specification page
        -- ngx.header["Location"] = "https://api-spec-url";
        -- return "https://api-spec-url\n", 301;
        return "{ \"error\": \"Bad request - missing address\" }", 404;
      end,
            
      [ "/address_lookup/*address" ] = postal_address_api_handler.make_address_insert_handler();
      
  },
  
  DELETE = {

      [ "/address_lookup" ] = function( params )
      
        -- TODO probably should redirect to API specification page
        -- ngx.header["Location"] = "https://api-spec-url";
        -- return "https://api-spec-url\n", 301;
        return "{ \"error\": \"Bad request - missing address\" }", 404;
      end,
            
      [ "/address_lookup/*address" ] = postal_address_api_handler.make_address_delete_handler();

  }
  
  });

-- route_request method should be invoked from Nginx config to start processing of incoming requests
function _router.route_request()

    ngx.ctx.is_connected = true;
    local start_time = ngx.time();
    
    local function on_abort_handler()
        local end_time = ngx.time();
        ngx.log( ngx.NOTICE, "Postal Address API - Connection was closed by client. Processing time ", end_time - start_time, " seconds." );
        ngx.ctx.is_connected = false;
    end
    
    local is_set, err = ngx.on_abort( on_abort_handler );
    if not is_set then
        ngx.log( ngx.DEBUG, "Postal Address API - Unable to set on_abort handler, error: ", err );
    end
    
    ngx.ctx.start_processing_time = ngx.now();

    local request_url = string.gsub(ngx.var.request_uri, "?.*", "");
    
    -- modify request_url - strip API's prefix and version
    local request_endpoint_root = postal_address_api_root;
    if ngx.var["postal_addres_api_endpoint"] and #ngx.var["postal_addres_api_endpoint"] > 0 then
        request_endpoint_root = ngx.var["postal_addres_api_endpoint"];
    end

    local request_endpoint_version = postal_address_api_version;
    if ngx.var["postal_addres_api_version"] and #ngx.var["postal_addres_api_version"] > 0 then
        request_endpoint_version = ngx.var["postal_addres_api_version"];
    end

    -- ngx.log( ngx.DEBUG, "Postal Address API - serving endpoint ", request_endpoint_root .. "/" .. request_endpoint_version );
    
    local request_url = string.gsub( request_url, request_endpoint_root .. "/" .. request_endpoint_version, "" );
    
    -- ngx.log( ngx.DEBUG, "Postal Address API - routing URL: ", request_url );
     
    -- execute router (which will invoke a proper request's handler)
    local execute_status, routing_status, response, http_status = pcall( function ()
        local ok, response_data, response_status = r:execute(
              ngx.var.request_method,
              request_url, 
              ngx.req.get_uri_args(),  -- all these parameters
              { ngx_req = ngx.req, ngx_ctx = ngx.ctx, request_method = ngx.var.request_method },
              { other_arg = 1 })       -- into a single "params" table
              
        return ok, response_data, response_status;
    end );
    
    if not execute_status and not response then
        ngx.log( ngx.ERR, "Postal Address API - routing execution failed - ", routing_status );
        response = "Internal server error."
    end
    
    if not ngx.ctx.is_connected then ngx.exit(499); return; end -- Nginx expects 499 for aborted requests
    
    ngx.header["Content-Type"] = "application/json";
    ngx.header["Access-Control-Allow-Origin"] =  "*";
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS";
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type, Access-Control-Allow-Origin, Cache-Control, Pragma, Expires, x-svc-status-token, x-svc-status-json-format";
    ngx.header["Access-Control-Max-Age"] = "86400";
    ngx.header["Origin"] = ngx.var.http_host;
    ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate";
    ngx.header["Pragma"] = "no-cache";
    ngx.header["Expires"] = "0"; 
    
    -- ngx.update_time();
    ngx.ctx.end_processing_time = ngx.now();
    
    if ngx.ctx.end_processing_time - ngx.ctx.start_processing_time > 2 then
        ngx.log( ngx.NOTICE, "Postal Address API - Long response time - processing request has took ", ngx.ctx.end_processing_time - ngx.ctx.start_processing_time, " seconds." );
    end
     
    if execute_status and routing_status then
          ngx.status = http_status;
          ngx.print( response .. "\n" );
          ngx.exit(ngx.status);
    elseif execute_status then
          ngx.status = 404;
          ngx.print("{ \"error\": \"Postal Address API - "..response.."\" }\n");
          ngx.log(ngx.ERR, response);
          ngx.exit(ngx.status);
    else
          ngx.status = 500;
          ngx.print("{ \"error\": \"Postal Address API - unable to process request\" }\n");
          ngx.log(ngx.ERR, "Postal Address API - request processing error: ", response);
          ngx.exit(ngx.status);    
    end

end

return _router;
