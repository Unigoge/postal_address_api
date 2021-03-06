local cjson = require "cjson"
local pretty_json = require "JSON";

local resty_sha256 = require "resty.sha256";
local resty_strings = require "resty.string";

local utils = require "utils";
local libpostal = require "postal";

local _address = {
    _VERSION = '0.01',
}

local mt = { __index = _address }

local postal_address_places_class = require "postal_address_places_class";

--[[

Routing metatable for address lookups is a part of API's configuration.
It could be stored remotely (in Git) and APIs instances could load it on demand
(decoding JSON into lookup_routing_table data structures) 

This table links lookup DB's routing tag with lookup "driver" and its configuration parameters

Only Nginx Shared Dictionaries driver is implemented at this moment. Drivers for Redis and/or Elastic Search & etc.
could be implemented in the future.

Format:
{
  routing_tag1 = {
    "driver" = "nginx_shared_lookup",
    "config" = {
        "shared_dictionary_name" = "newjersey07920"
    }
  },
  ...
  routing_tagN = {
    "driver" = "nginx_shared_lookup",
    "config" = {
        "shared_dictionary_name" = "manhattannewyorkcity10001"
    }
  }  
}

]]--

local lookup_routing_table = {
  ["07920"] = {
    ["driver"] = "nginx_shared_lookup",
    ["config"] = {
        ["shared_dictionary_name"] = "newjersey07920"
    }
  },
  ["10001"] = {
    ["driver"] = "nginx_shared_lookup",
    ["config"] = {
        ["shared_dictionary_name"] = "newyork10001"
    }
  },
  ["default"] = {
    ["driver"] = "nginx_shared_lookup",
    ["config"] = {
        ["shared_dictionary_name"] = "default_postal_lookup_dict"
    }
  }  
};

function _address.nginx_shared_lookup( op, key, config, address_object )

    if not config.shared_dictionary_name then
        ngx.log( ngx.ERR, "Postal Address API - configuration is missing shared dictionary name." );
        return nil;
    end
    
    local dict = ngx.shared[config.shared_dictionary_name];
    if not dict then
        ngx.log( ngx.ERR, "Postal Address API - shared dictionary ", config.shared_dictionary_name, " is not configured in Nginx configuration." );
        return nil;
    end
    
    if op == "get" then
        local address_json = dict:get( key );
        if address_json then
            local op_status, address_object = pcall( cjson.decode, address_json );
            if address_object and type( address_object ) == "table" then
                return address_object;
            else
                return nil;
            end
        else
            return nil;
        end
    elseif op == "set" and address_object and type( address_object ) == "table" then
        local op_status, address_json = pcall( cjson.encode, address_object );
        if op_status and address_json then
            return dict:set( key, address_json ); 
        else
            return nil;
        end        
    elseif op == "delete" then
    
    else
        return nil;
    end
end

function _address.db_lookup( key, routing_tag )

    if lookup_routing_table then
        if not routing_tag then
            routing_tag = "default";
        end
        
        local routing_table = lookup_routing_table[ routing_tag ];
        if routing_table then
            if routing_table.driver and routing_table.config and _address[ routing_table.driver ] then
                return _address[ routing_table.driver ]( "get", key, routing_table.config );
            end
        else
            ngx.log( ngx.INFO, "Postal Address API - unable to find routing table for tag ", routing_tag );
        end
    end
    
    return nil;
end

function _address.db_insert( key, address_object, routing_tag )

    if lookup_routing_table then
        if not routing_tag then
            routing_tag = "default";
        end
        
        local routing_table = lookup_routing_table[ routing_tag ];
        if routing_table then
            if routing_table.driver and routing_table.config and _address[ routing_table.driver ] then
                return _address[ routing_table.driver ]( "set", key, routing_table.config, address_object );
            end
        else
            ngx.log( ngx.INFO, "Postal Address API - unable to find routing table for tag ", routing_tag );
        end
    end
    
    return nil;
end

--[[

libpostal.parse_address( "119 west 24th street new york ny" )
returns table:
{
 state = "ny",
 house_number = "119",
 city = "new york",
 road = "west 24th street",
}

or libpostal.parse_address( "119 w 24th str, Manhattan New York, NY" )
returns table:
{
 city = "new york",
 state = "ny",
 road = "west 24 street",
 city_district = "manhattan",
 house_number = "119",
}

-----

libpostal.expand_address( "119 w 24th str, New York, NY" )
returns iterator which returns strings
119 w 24th street new york ny
119 w 24th street new york new york
119 west 24th street new york new york
119 west 24th street new york ny

]]--

local common_road_types = {
  "street",
  "avenue",
  "place",
  "circle",
  "square",
  "boulevard",
  "road",
  "drive",
  "way",
  "alley",
  "highway",
  "line",
  "route",
  "parkway"
};

local common_directions = {
  "west",
  "east",
  "south",
  "north"
};

--[[

Data structures:
{
 address = {
  country,       (optional)
  city,          (required)
  city_district, (optional)
  state,         (required)
  postcode,      (to be detected during address expansion)
  road,          (required)
  house,         (optional - "Empire State Building" for example)
  house_number,  (required if it is not a well known "house")
  lat,           (to be detected during address lookup)
  lng            (to be detected during address lookup)
 },
 address_options = { (sorted by weight)
  {
    country,
    city,          
    city_district, 
    state,         
    postcode,                 (to be detected during address expansion if not provided)  
    road,          
    house,         
    house_number,
    weight,                   (to be calculated during address expansion)
    addresses_db_routing_tag, (required to perform address lookup - constructed from "state", "city" and/or "postal_code")  
    lat,                      (to be detected during address lookup)
    lng                       (to be detected during address lookup)  
  },
  ...
  {
    ...
  }
 },
 validated_addresses_map = {}; -- collects full addresses for all validated places
 
--]]

function _address.get_new_address( address_string, language, country )

    local default_language = "en";
    local default_country = "us";
    
    if not address_string then
        return nil, "no address";
    end
    if not language then
        language = default_language;
    end
    if not country then
        country = default_country;
    end
    
    local ok, original_address = pcall( libpostal.parse_address, string.lower(address_string), language, country );
    if not ok then
        return nil, "unable to parse address";
    end
    
    -- need to normalize original address to split alpha from numeric for roads
    if original_address.road then
        local road_prefix = nil;
        local split = string.find( original_address.road, "(%a)(%d+)" );
        if split then
            road_prefix = string.sub( original_address.road, 1, split );
            original_address.road = road_prefix .. " " .. string.sub( original_address.road, split + 1 )
        end
    end

    -- house_number could also have trailing alphas - however that could be valid - need to add address option
    local original_address_options = {};
    if original_address.house_number then
        local house_number = nil;
        local split = string.find( original_address.house_number, "(%d)(%a+)" );
        if split then
        
            local address_option = {};
            address_option.country       = original_address.country;
            address_option.city          = original_address.city;
            address_option.city_district = original_address.city_district;
            address_option.state         = original_address.state;
            address_option.postcode      = original_address.postcode;
            address_option.road          = original_address.road;
            address_option.house         = original_address.house;
            address_option.house_number  = original_address.house_number;

            address_option.house_number = string.sub( original_address.house_number, 1, split );
            if original_address.road then
                address_option.road = string.sub( original_address.house_number, split + 1 ) .. " " .. original_address.road;
            else
                address_option.road = string.sub( original_address.house_number, split + 1 );
            end

            original_address_options[ #original_address_options + 1 ] = address_option;
        end
    end
    
    
    local address_table = {};
    address_table.country       = original_address.country;
    address_table.city          = original_address.city;
    address_table.city_district = original_address.city_district;
    address_table.state         = original_address.state;
    address_table.postcode      = original_address.postcode;
    address_table.road          = original_address.road;
    address_table.house         = original_address.house;
    address_table.house_number  = original_address.house_number;
    
    return setmetatable( { 
                            _type = "__address",
                            _data = {
                                address                 = address_table,
                                address_options         = original_address_options,
                                validated_addresses_map = {},
                                language                = language,
                                country                 = country
                            }
                         }, mt);
end

function _address.format_to_string( address_object )

    local address_string = "";
    if address_object.house then
        address_string = address_object.house;
    end
    if address_object.house_number then
        if #address_string == 0 then
            address_string = address_object.house_number;
        else
            address_string = address_string .. " " .. address_object.house_number;
        end
    end
    if address_object.road then
        if #address_string == 0 then
            address_string = address_object.road;
        else
            address_string = address_string .. " " .. address_object.road;
        end
    end
    if address_object.city_district then
        if #address_string == 0 then
            address_string = address_object.city_district;
        else
            address_string = address_string .. ", " .. address_object.city_district;
        end
    end
    if address_object.city then
        if #address_string == 0 then
            address_string = address_object.city;
        else
            address_string = address_string .. ", " .. address_object.city;
        end
    end
    if address_object.state then
        if #address_string == 0 then
            address_string = address_object.state;
        else
            address_string = address_string .. ", " .. address_object.state;
        end
    end
    if address_object.postcode then
        if #address_string == 0 then
            address_string = address_object.postcode;
        else
            address_string = address_string .. ", " .. address_object.postcode;
        end
    end
    if address_object.country then
        if #address_string == 0 then
            address_string = address_object.country;
        else
            address_string = address_string .. " " .. address_object.country;
        end
    end

    return address_string;
end

function _address.format_to_json( address_option_object, params )

    if not address_option_object then
        return  "{ \"error\": \"Postal Address API - unable to process request - building response error\" }\n", 500;
    end
    
    local response_json_table = {};
    response_json_table["address"] = _address.format_to_string( address_option_object );
    if address_option_object.country and #address_option_object.country > 0 then
        response_json_table["country"] = address_option_object.country;
    elseif params and params["country"] and #params["country"] > 0 then
        response_json_table["country"] = params["country"];
    end
    if params and params["language"] and #params["language"] > 0 then
        response_json_table["language"] = params["language"];
    end
    if address_option_object.lat then
        response_json_table["lat"] = address_option_object.lat;
    end
    if address_option_object.lng then
        response_json_table["lng"] = address_option_object.lng;
    end
    
    local response_json = pretty_json:encode_pretty( response_json_table );
    if response_json then
        return response_json, 200;
    else
        return  "{ \"error\": \"Postal Address API - unable to process request - building response error\" }\n", 500; 
    end    
end

function _address.update_address( address_class_object, address_object )

    if address_class_object._type and address_class_object._type ~= "__address" then
        return;
    end
    
    if address_class_object._data and address_class_object._data.address then
        utils.tableMerge( address_class_object._data.address, address_object );
    else
        -- just do it - no guarantees
        utils.tableMerge( address_class_object, address_object );
    end
end

function _address.expand_address( self )

    local error_message = nil;
    
    --
    -- the first step - use libpostal.expand_address to populate address_options
    --
    local existing_address_options = nil;
    if self._data.address_options and #self._data.address_options > 0 then
        existing_address_options = utils.tablecopy( self._data.address_options );
    end
    
    local ok, expanded_results_reader = pcall( libpostal.expand_address, _address.format_to_string( self._data.address ),{ languages = { self._data.language } } );
    if ok and type( expanded_results_reader ) == "function" then -- it returns an iterator
        local result = expanded_results_reader();
        while result do
            local ok, address_option = pcall( libpostal.parse_address, result, self._data.language, self._data.country );
            if ok then
                -- chek if it contains at least some of required information
                if ( address_option.road and address_option.house_number ) or address_option.house then
                    local address_table = {};
                    address_table.country       = address_option.country;
                    address_table.city          = address_option.city;
                    address_table.city_district = address_option.city_district;
                    address_table.state         = address_option.state;
                    address_table.postcode      = address_option.postcode;
                    address_table.road          = address_option.road;
                    address_table.house         = address_option.house;
                    address_table.house_number  = address_option.house_number;
                    address_table.weight        = 0;
                    self._data.address_options[ #self._data.address_options + 1 ] = address_table;                   
                end
            end
            result = expanded_results_reader();
        end
    elseif type( expanded_results_reader ) == "string" then
        error_message = "unable to expand address - " .. expanded_results_reader;
    else
        error_message = "unable to expand address";
    end
    
    if existing_address_options then
        local existing_address_option;
        for _, existing_address_option in ipairs( existing_address_options ) do
            local ok, expanded_results_reader = pcall( libpostal.expand_address, _address.format_to_string( existing_address_option ),{ languages = { self._data.language } } );
            if ok and type( expanded_results_reader ) == "function" then -- it returns an iterator
                local result = expanded_results_reader();
                while result do
                    local ok, address_option = pcall( libpostal.parse_address, result, self._data.language, self._data.country );
                    if ok then
                        -- chek if it contains at least some of required information
                        if ( address_option.road and address_option.house_number ) or address_option.house then
                            local address_table = {};
                            address_table.country       = address_option.country;
                            address_table.city          = address_option.city;
                            address_table.city_district = address_option.city_district;
                            address_table.state         = address_option.state;
                            address_table.postcode      = address_option.postcode;
                            address_table.road          = address_option.road;
                            address_table.house         = address_option.house;
                            address_table.house_number  = address_option.house_number;
                            address_table.weight        = 0;
                            self._data.address_options[ #self._data.address_options + 1 ] = address_table;                   
                        end
                    end
                    result = expanded_results_reader();
                end
            end
        end    
    end
    
    --
    -- second step - validate addresses from address_options
    --
    local places = postal_address_places_class.new();
    
    if #self._data.address_options == 0 then
        -- should at least try to validate an original address
        -- validate_address could return additional address options
        local addresses_db_routing_tag, alternative_address_options = places:validate_address( self._data.address, self._data.language, self._data.country );
        if not addresses_db_routing_tag and not alternative_address_options then
            -- failed!
            if error_message then
                return error_message;
            else
                return "unable to expand address";
            end
        end
        self._data.address.addresses_db_routing_tag = addresses_db_routing_tag;
        self._data.address_options[ 1 ] = utils.tablecopy( self._data.address );
        
        if alternative_address_options then
            local idx, address_option;
            for idx, address_option in ipairs( alternative_address_options ) do
                self._data.address_options[ #self._data.address_options + 1 ] = address_option;
            end
        end
    end
    
    -- ngx.log( ngx.DEBUG, "Postal Address API - validating address options:\n", utils.serializeTable( self._data.address_options ) );
    
    if #self._data.address_options ~= 0 then
        -- should try to validate places for all address options
        local idx, address_option;
        for idx, address_option in ipairs( self._data.address_options ) do
        
            if not address_option.addresses_db_routing_tag then
                -- ngx.log( ngx.DEBUG, "Postal Address API - validating address option:\n", utils.serializeTable( address_option ) );
                -- validate_address could return additional address options
                local addresses_db_routing_tag, alternative_address_options = places:validate_address( address_option, self._data.language, self._data.country );
                address_option.addresses_db_routing_tag = addresses_db_routing_tag;
                if alternative_address_options and type( alternative_address_options ) == "table" then
                    -- ngx.log( ngx.DEBUG, "Postal Address API - alternative address options:\n", utils.serializeTable( alternative_address_options ) );
                    local idx, alternative_address_option;
                    for idx, alternative_address_option in ipairs( alternative_address_options ) do
                        self._data.address_options[ #self._data.address_options + 1 ] = alternative_address_option;
                    end
                end
            end
            
            if address_option.addresses_db_routing_tag then
                -- validated!
                address_option.weight = 1;
                
                -- calculate address option weight over here
                -- check if road name containes any of common types
                if address_option.road then
                    local idx, road_type;
                    for idx, road_type in ipairs( common_road_types ) do
                        if string.find( address_option.road, road_type ) then
                            address_option.weight = address_option.weight + 5;
                            if string.find( address_option.road, "(%d+)st " .. road_type )
                                or string.find( address_option.road, "(%d+)nd " .. road_type )
                                or string.find( address_option.road, "(%d+)rd " .. road_type )
                                or string.find( address_option.road, "(%d+)th " .. road_type ) then
                                
                                address_option.weight = address_option.weight - 2;
                            end
                            break;
                        end
                    end
                    -- check if road name containes any of common directions
                    local idx, road_direction;
                    for idx, road_direction in ipairs( common_directions ) do
                        if string.find( address_option.road, road_direction ) then
                            address_option.weight = address_option.weight + 5;
                            break;
                        end
                    end
                end                
                -- check if address_option include a house name
                if address_option.house then
                    address_option.weight = address_option.weight + 1;
                end
                
                --
                -- add validated address option into validated_addresses_map
                -- construct a key and sha256 it
                local key = _address.format_to_string( address_option ) .. " " .. address_option.addresses_db_routing_tag;
                
                local sha256 = resty_sha256:new();
                sha256:update( key );
                local key_sha256 = resty_strings.to_hex( sha256:final() );
                if not self._data.validated_addresses_map[ key_sha256 ] then
                    self._data.validated_addresses_map[ key_sha256 ] = address_option;
                end               
            end
        end
        
        -- ngx.log( ngx.DEBUG, "Postal Address API - validated addresses map:\n", utils.serializeTable( self._data.validated_addresses_map ) );
        --
        -- third step - reduce address options array to valid and unique only
        --
        -- all valid and unique address options should be referenced by validated_addresses_map at this point
        -- should reconstruct address_options array from it
        --
        self._data.address_options = {}; -- discard existing data
        local map_key, map_value;
        for map_key, map_value in pairs( self._data.validated_addresses_map ) do
            self._data.address_options[ #self._data.address_options + 1 ] = map_value;
        end
        
        -- sort address options accordingly to weight
        table.sort( self._data.address_options, function( a, b ) 
            return a.weight > b.weight;
        end );
        -- ngx.log( ngx.DEBUG, "Postal Address API - validated address_options:\n", utils.serializeTable( self._data.address_options ) );
    end
    
    return nil;
end

function _address.get_number_of_address_options( self )
    return #self._data.address_options;
end

-- this method returns address options by number or by original address postcode
function _address.get_address_option( self, option_number )
    
    if not option_number and self._data.address.postcode then
        -- search for address option with the same postcode as inside original address
        local address_option;
        for _, address_option in ipairs( self._data.address_options ) do
            if address_option.postcode and address_option.postcode == self._data.address.postcode then
                return address_option;
            end
        end
        return nil;
         
    elseif option_number and option_number <= #self._data.address_options then
        return self._data.address_options[ option_number ];
    else
        return nil;
    end
end

function _address.is_ready_for_lookup( self, address_option_object )
    if ( not address_option_object.house_number or not address_option_object.road or not address_option_object.city )
       and ( not address_option_object.house or not address_option_object.city ) then
       
       return false;
    end
    return address_option_object.addresses_db_routing_tag;
end

-- this method inserts lat/long into address_option_object
function _address.lookup_address_option( self, address_option_object )

    if not address_option_object.addresses_db_routing_tag then
        return "no lookup DB routing information", nil;
    end
    
    local key = _address.format_to_string( address_option_object );
    -- ngx.log( ngx.DEBUG, "Postal Address API - address lookup - building key for: \"", key, "\"" );
    
    local sha256 = resty_sha256:new();
    sha256:update( key );
    local key_sha256 = resty_strings.to_hex( sha256:final() );
    
    local address = _address.db_lookup(key_sha256, address_option_object.addresses_db_routing_tag);
    if address and address.lat and address.lng then
        address_option_object.lat = address.lat
        address_option_object.lng = address.lng;
        
        -- ngx.log( ngx.DEBUG, "Postal Address API - address lookup - found:\n", utils.serializeTable( address ) );
        
        return nil, true;
    elseif address then
        ngx.log( ngx.INFO, "Postal Address API - address lookup - no lat/long - found:\n", utils.serializeTable( address ) );
    end
    
    return nil, false;    
end

-- this methods iterates over address options array (sorted by weight) and returns the first element with lat/long
function _address.get_verified_address( self )

    if self._data.address.lat and self._data.address.lng then
        return self._data.address;
    end
    
    local idx, address_option;
    for idx, address_option in ipairs( self._data.address_options ) do
        if address_option.lat and address_option.lng then
            self._data.address = utils.tablecopy( address_option );
            table.remove( self._data.address_options, idx );
            return self._data.address;
        end
    end
    
    return nil;
end

function _address.insert_address( self, address_option_object, lat, lng )

    if not address_option_object.addresses_db_routing_tag then
        return "no lookup DB routing information", nil;
    end

    if not lat or not lng then
        return "no lat/long", nil;    
    end

    local address = utils.tablecopy( address_option_object );
    address.lat = lat;
    address.lng = lng;
          
    local key = _address.format_to_string( address_option_object );
    
    local sha256 = resty_sha256:new();
    sha256:update( key );
    local key_sha256 = resty_strings.to_hex( sha256:final() );
    
    local ok, err = _address.db_insert(key_sha256, address, address_option_object.addresses_db_routing_tag);
    -- ngx.log( ngx.DEBUG, "Postal Address API - inserted address \"", key, "\", ok == ", ok, " error: ", err );
    if ok then
        _address.update_address( self, address );
        return nil, true;
    end
    if err then
        return err, false;
    else
        return "unable to insert address", false;
    end
end

function _address.delete_address( self, address_option_object )

end

return _address;