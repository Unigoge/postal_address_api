# The design

Project is bult as Nginx/Openresty/Lua app that implements a postal address lookup API as part of bigger infrastructure 
(which provides databases for validation of enetered address "city", "state", "postal_code" & etc). Also API depends on
availability of key/value datastore(s) with lat/long records for each valid street address.

Additional configuration and routing metadata has to be mantained to provide information about topology of DBs and key/value datastores.

# The API

GET

expects URL that end as `"../424+South+Maple+Ave+Basking+Ridge+NJ+07920?language=en&country=us"` (could also use `%20` for spaces or any other common URL encoding)

"language" and "country" query parameters are optional

POST

expects JSON body with an array of JSON objects:
```
[
    { "address": "424 South Maple Ave Basking Ridge NJ 07920", "language": "en", "country": "us" },
    { "address": "119 w 24th st, New York, NY", "language": "en" },
]
```

"language" and "country" attributes are optional

PUT

expects JSON object with following attributes:

```
{
    "address": "424 South Maple Ave Basking Ridge NJ 07920",
    "language": "en", 
    "country": "us",
    "lat": 40.6863623,
    "lng": -74.53439190000002,
}
```

"language", "country", "lat", "lng" attributes are optional

The address is expected to be free of typos and it should include all essential parts and postal code

DELETE

expects URL that end as `"../424+South+Maple+Ave+Basking+Ridge+NJ+07920?language=en&country=us"` (could also use `%20` for spaces or any other common URL encoding)

"language" and "country" query parameters are optional

The address is expected to be free of typos and it should include all essential parts and postal code

# The API handlers

"make_XXXXX" methods are expected to be invoked from Nginx requests execution contex.

The methods which implement "lookup", "insert" and "delete" logic could invoked from tests and CLI (batch processing tools)

# Class "address"

This class implements functionality of address parsing and expands an received address into multiple valid options (via libpostal).
For each valid address the class performs an asyncronous lookup into key/value datastore to get lat/long information about particular
street address. Since all valid address options are assigned a "weight" (based on correctness of provided information) then the address
with highest "weigth" is returned.
 
Data structures:

```
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
 }
}
```

Routing metatable for address lookups is a part of API's configuration.
It could be stored remotely (in Git) and APIs instances could load it on demand
(decoding JSON into lookup_routing_table data structures) 

This table links lookup DB's routing tag with lookup "driver" and its configuration parameters

Only Nginx Shared Dictionaries driver is implemented at this moment. Drivers for Redis and/or Elastic Search & etc.
could be implemented in the future.

Format:
```
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
```

# Class "places":

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

```
| "city name" | "city alternative name" | "state name" | "postal_code" | "routing_tag" |
```

if "routing_tag" is empty it is assumed to be equal to "postal_code"

The "common_names" database table should include following columns

```
| "common_name" | "place_type" | "city name" | "state name" | "country name" | "postal_code" | "routing_tag" |
```

where "place_type" should be an element of enumeration of { "house", "city", "city_district", "state", "country" }

In case of international addresses (and "country" records) the "routing_tag" should include all information that is necessary to 
execute queries against corresponding database.

Routing metatable for address lookups is a part of API's configuration.
It could be stored remotely (in Git) and APIs instances could load it on demand
(decoding JSON into lookup_routing_table data structures) 

This table links lookup DB's routing tag with lookup "driver" and its configuration parameters

# libpostal

Now, the most challenging part of the project would be handling of incomplete, partial, and/or addresses with typos. 
After the short Google search I have found libpostal ( https://github.com/openvenues/libpostal ) which looks like a very 
good solution for this problem ( good read - https://mapzen.com/blog/inside-libpostal/ - I definitely would need to spend 
more time reading about it - but on the surface it is based on the most complete and up-to-date set of data).

There are multiple language binding for this library (including my favorite Lua -  https://github.com/bungle/lua-resty-postal ).
Or it can be used directly from written in C handler (Nginx- or Apache-module). 

```
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

libpostal.expand_address( "119 w 24th str, New York, NY" )
returns iterator which returns strings
119 w 24th street new york ny
119 w 24th street new york new york
119 west 24th street new york new york
119 west 24th street new york ny
```
     
