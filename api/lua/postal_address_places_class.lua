local cjson = require "cjson"
local pretty_json = require "JSON";

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

local _places = {
    _VERSION = '0.01',
}

local mt = { __index = _places }


function _places.new()

    return setmetatable( { 
                            _data = {
                                validated_places_map = {},
                                validated_addresses_map = {};
                            }
                         }, mt);
end

function _places.validate_address( self, address_option_object, language, country )

end

return _places;


