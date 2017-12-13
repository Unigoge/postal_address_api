
local postal = require("postal");

local ok, error = pcall( postal.setup );
if not ok then
	ngx.log( ngx.ERR, "Unable to setup libpostal: ", error );
end
