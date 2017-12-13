local cjson = require "cjson"
local pretty_json = require "JSON";

local resty_sha256 = require "resty.sha256";
local resty_strings = require "resty.string";

local utils = require "utils";

--[[

This class implements functionality of mapping information of "city", "city_district", "state", "country", and "house" (a well known building name)
to "postal_code" and "routing_tag" (this tag could be used to direct requests to particular key/value store for fast lookup of individual street addresses). 

This class should communicate with database and could execute SQL queries on several DB tables:

- if the input is an USA address (default) then it should query individual "states" tables for information about particular 
  "city" and/or "city_districts" names (the table should mantain a collection of all valid names);
- if previous search has failed (and/or input has no "city" or "state" information) - then it should query a "common_names" table,
  sending multiple queries for "house" (a well known building name), then for "city_district", then for "city" and "state" (in case
  of international addresses where input did not include "country")
- if the input is an international address then the input should include "country" - so the "city"/"state" search could be directed to
  a proper database (or micro-service via REST API requests).
  
The "state" database table should include following columns:

| "city name" | "city alternative name" | "state name" | "postal_code" | "routing_tag" |

if "routing_tag" is empty it is assumed to be equal to "postal_code"

The "common_names" database table should include following columns

| "common_name" | "place_type" | "city name" | "state name" | "country name" | "postal_code" | "routing_tag" |

where "place_type" should be an element of enumeration of { "house", "city", "city_district", "state", "country" }

In case of international addresses (and "country" records) the "routing_tag" should include all information that is necessary to 
execute queries against corresponding database.

Routing metatable for address lookups is a part of API's configuration.
It could be stored remotely (in Git) and APIs instances could load it on demand
(decoding JSON into lookup_routing_table data structures) 

This table links lookup DB's routing tag with lookup "driver" and its configuration parameters
     
]]--

local db_routing_table = {
  ["canada"] = {
    ["driver"] = "google_map_api_lookup",
    ["config"] = {
        ["url"]  = "http://maps.googleapis.com/maps/api/geocode/json?sensor=false",
        ["method"] = "GET"
    }
  },
  ["us"] = {
    ["driver"] = "mock_data_lookup",
    ["config"] = {
    }
  },  
  ["default"] = {
    ["driver"] = "mock_data_lookup",
    ["config"] = {
    }
  }  
};

local postal_address_addr_class = require "postal_address_api_addr_class";

local _places = {
    _VERSION = '0.01',
}

local mt = { __index = _places }

function _places.new()

    return setmetatable( { 
                            _data = {
                                validated_places_map = {},    -- for a life time of the object: collects all 
                                                              -- validated places - "city"."state"."postcode" as a key
                            }
                         }, mt);
end

function _places.query_db( scope, address_object, country )

    if db_routing_table then
        if address_object.country then
            country = address_object.country
        elseif not country then
            country = "default";
        end
        
        
        local routing_table = db_routing_table[ country ];
        if not routing_table then
            routing_table = db_routing_table[ "default" ];
        end
        if routing_table then
            if routing_table.driver and routing_table.config and _places[ routing_table.driver ] then
                return _places[ routing_table.driver ]( scope, address_object, routing_table.config );
            end
        else
            ngx.log( ngx.INFO, "Postal Address API - unable to find routing table for country ", country );
        end
    end
    
    return nil;
end

function _places.validate_address( self, address_object, language, country )

    local found_routing_tag = nil;
    local alternative_address_options = nil;
    
    local verified_places = {};
    local address_options = {};
    
    if address_object.routing_tag then
        return address_object.routing_tag;
    end
    
    --
    -- try to fetch from validated_places_map for input address_option_object
    --
    -- construct a key and sha256 it
    local key;
    if address_object.city_district and address_object.city and address_object.state then
        key = address_object.city_district .. " " .. address_object.city .. " " .. address_object.state;
    elseif address_object.city and address_object.state then
        key = address_object.city .. " " .. address_object.state;
    end
    if key then
        local sha256 = resty_sha256:new();
        sha256:update( key );
        local key_sha256 = resty_strings.to_hex( sha256:final() );
        
        if self._data.validated_places_map[ key_sha256 ] then
            verified_places = self._data.validated_places_map[ key_sha256 ];
        end
    end        

    
    --
    -- initialize queue of address options to verify
    --
    address_options[1] = utils.tablecopy( address_object );
    
    local loops_count = 5; -- should never take more than 5 runs to finish a search
    while( #verified_places == 0 and #address_options ~= 0 and loops_count > 0 ) do

        --
        -- try searching "places" DB for - ("city_district" and "state) or ("city" and "state")
        --
        -- since address_options is a queue - always use address_options[1]
        local fetched_places = _places.query_db( "states", address_options[1], country );
        if fetched_places and type( fetched_places ) == "table" and #fetched_places ~= 0 then
            local idx, place_record;
            for idx, place_record in ipairs( fetched_places ) do
                if place_record.postcode or place_record.routing_tag then
                    verified_places[ #verified_places + 1 ] = utils.tablecopy( place_record );
                end
            end
        else
            -- not found!
            --
            -- need to search "common_names" now
            --
            local fetched_common_places = _places.query_db( "states", address_options[1], country );
            if fetched_common_places and type( fetched_common_places ) == "table" and #fetched_common_places ~= 0 then
                local idx, place_record;
                for idx, place_record in ipairs( fetched_common_places ) do
                    if place_record.postcode or place_record.routing_tag then
                        --
                        -- most likely got a "house" - a well known place
                        --
                        -- check if found place matches an attribute in address_option
                        -- otherwise - just discard it
                        if address_options[1][ place_record.type ] and address_options[1][ place_record.type ] == place_record.name then
                            verified_places[ #verified_places + 1 ] = utils.tablecopy( place_record );
                        end
                    else
                        -- need to push found place into address_options - it will get verified at one of the next iterations
                        local new_address_option = utils.tablecopy( address_options[1] );
                        utils.tableMerge( new_address_option, place_record );
                        new_address_option.name = nil; -- remove artifacts
                        new_address_option.type = nil;
                        address_options[ #address_options + 1 ] = new_address_option;
                    end
                end
            end            
        end
        table.remove( address_options, 1 ); -- move the queue forward
        loops_count = loops_count - 1;
    end
    
    -- update address_object and process alternative_address_options if needed
    --
    -- this version does not use "streets" class to reduce number of verified_places - not yet.
    --
    if #verified_places > 0 then
        -- first element updates address that was passed as an argument
        postal_address_addr_class.update_address( address_object, verified_places[1] );
        found_routing_tag = verified_places[1].routing_tag;
        
        -- update validated_places_map
        -- construct a key and sha256 it
        local key;
        if address_object.city_district and address_object.city and address_object.state then
            key = address_object.city_district .. " " .. address_object.city .. " " .. address_object.state;
        elseif address_object.city and address_object.state then
            key = address_object.city .. " " .. address_object.state;
        end
        if key then
            local sha256 = resty_sha256:new();
            sha256:update( key );
            local key_sha256 = resty_strings.to_hex( sha256:final() );
            
            if not self._data.validated_places_map[ key_sha256 ] then
                self._data.validated_places_map[ key_sha256 ] = utils.tablecopy( verified_places ); 
            end
        end        
        
        -- construct alternative_address_options starting from 2nd validated_places element
        local verified_places_length = #verified_places - 1;
        if verified_places_length > 0 then
            alternative_address_options = {};        
            local idx = 2;
            while idx <= verified_places_length do
                local address_object_copy = utils.tablecopy( address_object );
                postal_address_addr_class.update_address( address_object_copy, verified_places[ idx ] );
                alternative_address_options[ #alternative_address_options + 1 ] = address_object_copy;
            end
        end
    end
    
    return found_routing_tag, alternative_address_options;
end

--[[

Mock data and Google API lookup drivers - for testing only
 
]]--

function _places.google_map_api_lookup( scope, address_option_object, config )

    local url = "http://maps.googleapis.com/maps/api/geocode/json?sensor=false";
    if config["url"] then
        url = config["url"];
    end
    
    if scope == "states" or scope == "common_names" then
    
        local address_query = postal_address_addr_class.format_to_string( address_option_object );

        if #address_query == 0 then
            -- no "city" and "state"
            return nil;
        end
        
        address_query = "&address=" .. ngx.escape_uri( address_query );
        local google_response, err = utils.send_http_req( url, {
                                          method = "GET",
                                          headers = {
                                            ["Accept"] = "*/*"
                                          } 
                                     } );
        if not google_response then
            ngx.log( ngx.INFO, "Postal Address API - Google request error: ", err );
        else
            local ok, google_response_object = pcall( cjson.decode, google_response );
            if not ok or not google_response_object or type(google_response_object) ~= "table" then
                ngx.log( ngx.INFO, "Postal Address API - Unable to parse Google JSON" );
            else
                if google_response_object.results and google_response_object.results[1] then
                    google_response_object = google_response_object.results[1];
                end
                if google_response_object and google_response_object["address_components"] then
                    local city_record = {};
                    local idx, address_component;
                    for idx, address_component in ipairs( google_response_object["address_components"] ) do
                        local i, type;
                        for i, type in ipairs( address_component.types ) do
                            if type == "locality" then
                                city_record["city"] = address_component["long_name"];
                            elseif type == "administrative_area_level_1" then
                                city_record["state"] = address_component["short_name"];
                            elseif type == "postal_code" then
                                city_record["postcode"] = address_component["short_name"];
                            elseif type == "country" then
                                city_record["country"] = address_component["short_name"];
                            end
                        end
                    end
                    
                    if city_record["city"] then
                        return city_record;
                    else
                        return nil;
                    end
                end
            end
        end
        
        return nil;        
    end
                
    return nil;
end

local mock_db_data = {

    ["nj"] = { -- state short form
        ["basking ridge"] = { -- cities
            {
              ["city"]             = "basking ridge",
              ["city_alternative"] = "bernards",
              ["state"]            = "new jersey",
              ["postcode"]         = "07920",
              ["routing_tag"]      = "07920"
            }
        },
        ["new providence"] = {
            {
              ["city"]             = "new providence",
              ["city_alternative"] =  nil,
              ["state"]            = "new jersey",
              ["postcode"]         = "07974",
              ["routing_tag"]      = "default"
            }
        }
    },
    ["ny"] = {
        ["new york"] = { -- multiple zip codes
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         = "10001",
              ["routing_tag"]      = "10001"
            },
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         = "10011",
              ["routing_tag"]      = "default"
            },
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         =  nil,
              ["routing_tag"]      = "default"
            }            
        },
        ["nyc"] = { -- alternative city name used as "city"
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         = "10001",
              ["routing_tag"]      = "10001"
            },
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         = "10011",
              ["routing_tag"]      = "default"
            },
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         =  nil,
              ["routing_tag"]      = "default"
            }            
        },
        ["manhattan"] = { -- "city_district" used as "city"
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         = "10001",
              ["routing_tag"]      = "10001"
            },
            {
              ["city"]             = "new york",
              ["city_alternative"] = "nyc",
              ["state"]            = "new york",
              ["postcode"]         =  nil,
              ["routing_tag"]      = "default"
            }
        }            
    },
    ["common_names"] = {
        ["brooklyn"] = {
            ["name"]        = "brooklyn",
            ["type"]        = "city_district",
            ["city"]        = "new york",
            ["state"]       = "ny",
            ["country"]     = "us",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        },
        ["empire state building"] = {
            ["name"]        = "empire state building",
            ["type"]        = "house",
            ["city"]        = "new york",
            ["state"]       = "ny",
            ["country"]     = "us",
            ["postcode"]    = "10118",
            ["routing_tag"] = "default"
        },
        ["pennsylvania station"] = {
            ["name"]        = "pennsylvania station",
            ["type"]        = "house",
            ["city"]        = "new york",
            ["state"]       = "ny",
            ["country"]     = "us",
            ["postcode"]    = "10001",
            ["routing_tag"] = "10001"
        },
        ["united states"] = {
            ["name"]        = "united states",
            ["type"]        = "country",
            ["city"]        =  nil,
            ["state"]       =  nil,
            ["country"]     = "us",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        },        
        ["new jersey"] = {
            ["name"]        = "new jersey",
            ["type"]        = "state",
            ["city"]        =  nil,
            ["state"]       = "nj",
            ["country"]     = "us",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        },
        ["new york"] = {
            ["name"]        = "new york",
            ["type"]        = "state",
            ["city"]        =  nil,
            ["state"]       = "ny",
            ["country"]     = "us",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        },
        ["new york city"] = {
            ["name"]        = "new york city",
            ["type"]        = "city",
            ["city"]        = "new york",
            ["state"]       = "ny",
            ["country"]     = "us",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        },
        ["quebec"] = {
            ["name"]        = "quebec",
            ["type"]        = "state",
            ["city"]        =  nil,
            ["state"]       = "qc",
            ["country"]     = "canada",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        },        
        ["ontario"] = {
            ["name"]        = "ontario",
            ["type"]        = "state",
            ["city"]        =  nil,
            ["state"]       = "ot",
            ["country"]     = "canada",
            ["postcode"]    =  nil,
            ["routing_tag"] =  nil
        }                        
    }
};

function _places.mock_data_lookup( scope, address_option_object, config )
    
    if scope == "states" then
        -- a fast lookup - "state" AND "city" ( AND "postcode" - optional )
        if address_option_object.state and mock_db_data[ address_option_object.state ] then
            local state_db = mock_db_data[ address_option_object.state ];
            local city_db = nil;

            -- check for city_district first - it has higher priority
            if address_option_object.city_district and state_db[ address_option_object.city_district ] then
                city_db = state_db[ address_option_object.city_district ];
            elseif address_option_object.city and state_db[ address_option_object.city ] then
                city_db = state_db[ address_option_object.city ];
            end
            
            if city_db then
                if address_option_object.postcode then
                    local db_records = {};
                    local idx, record;
                    for idx, record in ipairs( city_db ) do
                        if record["postcode"] and record["postcode"] == address_option_object.postcode then
                            db_records[ #db_records + 1 ] = record;
                        end 
                    end
                    if #db_records > 0 then return db_records end
                else
                    -- done
                    return city_db;
                end            
            end
        end
        
        return nil;    
    elseif scope == "common_names" then
        -- "house" OR "city_district" OR "city" OR "state"
        local db_records = {};
        local idx, record;
        for idx, record in ipairs( mock_db_data[ "common_names" ] ) do
        
            if address_option_object.house and record["type"] == "house"
               and address_option_object.house == record["name"] then
               
               db_records[ #db_records + 1 ] = record;
               
            elseif address_option_object.city_district and record["type"] == "city_district"
               and address_option_object.city_district == record["name"] then
               
               db_records[ #db_records + 1 ] = record;
                
            elseif address_option_object.city and record["type"] == "city"
               and address_option_object.city == record["name"] then
               
               db_records[ #db_records + 1 ] = record;
               
            elseif address_option_object.state and record["type"] == "state"
               and address_option_object.state == record["name"] then
               
               db_records[ #db_records + 1 ] = record;
               
            elseif address_option_object.country and record["type"] == "country"
               and address_option_object.country == record["name"] then
               
               db_records[ #db_records + 1 ] = record;  
            end
        end
        
        if #db_records > 0 then return db_records;
        else return nil end
    end
    
    return nil;
end


return _places;


