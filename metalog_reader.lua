--[[
	metalog.lua is a script that reads METALOG file created by pkgbase
	(make packages) and generates reports about the installed system
	and issues
]]

function main(args)
	if #args == 0 then usage() end
	local filename = args[1]
	print(filename)
end

function usage()
	io.stderr:write('usage: '..arg[0].. ' <metafile path>\n')
	os.exit(1)
end

-- creates a table contaning file's info, from the line content from METALOG
-- all fields in the table are strings
-- sample output:
--	{
--		filename = ./usr/share/man/man3/inet6_rthdr_segments.3.gz
--		attrs = {
--			gname = 'wheel'
--			uname = 'root'
--			mode = '0444'
--			size = '1166'
--			time = nil
--			type = 'file'
--			tags = 'package=clibs,debug'
--		}
--	}
--- @param line string
function MetalogRow(line)
	local res, attrs = {}, {}
	local filename, rest = line:match('^(%S+) (.+)$')
	-- mtree file has space escaped as '\040', which becomes a '(' in Lua.
	-- all in all it doesn't affect parsing due to this "error", as we are
	-- spliting line by spaces
	for attrpair in rest:gmatch('[^ ]+') do
		local k, v = attrpair:match('^(.-)=(.+)')
		attrs[k] = v
	end
	res.filename = filename
	res.attrs = attrs
	return res
end

-- a table to represent a package
--- @param name string
--- @param files table<MetalogRow>
function Package(name, files)
	return {
		name = name,
		files = files
	}
end

--- @param metalog string
function Analysis_session(metalog)
	local files = {} -- array<MetalogRow>
	local pkgs = {} -- array<Package>
	-- used to count repeated files
	local filec = {} -- map<string, number>

	local fp, errmsg, errcode = io.open(metalog, 'r')
	if fp == nil then
		io.stderr:write('cannot open '..metalog..': 'errmsg..': '..errcode..'\n')
	end

	-- scan all lines and put file data into the array
	for line in fp:lines() do
		
	end

	fp:close()

end

x='./usr/share/man/man3/inet6\040rthdr\040segments.3.gz type=file uname=root gname=wheel mode=0444 size=1168 tags=package=clibs,debug'
for k, v in pairs(MetalogRow(x))do print(k,v)end
