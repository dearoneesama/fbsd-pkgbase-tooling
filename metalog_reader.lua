--[[
	metalog.lua is a script that reads METALOG file created by pkgbase
	(make packages) and generates reports about the installed system
	and issues
]]

function main(args)
	if #args == 0 then usage() end
	local filename = args[1]
	Analysis_session(filename)
end

function usage()
	io.stderr:write('usage: '..arg[0].. ' <metafile path>\n')
	os.exit(1)
end

--- @param t table
function sortedPairs(t)
    local sortedk = {}
    for k in next, t do sortedk[#sortedk+1] = k end
    table.sort(sortedk)
    local i = 0
    return function()
        i = i + 1
        return sortedk[i], t[sortedk[i]]
    end
end

--- @param array table
function array_all_equal(array)
	for _, v in ipairs(array) do
		if v ~= array[1] then return false end
	end
	return true
end

__MetalogRow_mt = {
	-- ignore lineno
	__eq = function(this, o)
		if this.filename ~= o.filename then return false end
		for k in pairs(this.attrs) do
			if this.attrs[k] ~= o.attrs[k] and o.attrs[k] ~= nil then return false end
		end
		return true
	end
}
-- creates a table contaning file's info, from the line content from METALOG
-- all fields in the table are strings
-- sample output:
--	{
--		filename = ./usr/share/man/man3/inet6_rthdr_segments.3.gz
--		lineno = 5
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
function MetalogRow(line, lineno)
	local res, attrs = {}, {}
	local filename, rest = line:match('^(%S+) (.+)$')
	-- mtree file has space escaped as '\\040', not affecting splitting
	-- string by space
	for attrpair in rest:gmatch('[^ ]+') do
		local k, v = attrpair:match('^(.-)=(.+)')
		attrs[k] = v
	end
	res.filename = filename
	res.linenum = lineno
	res.attrs = attrs
	setmetatable(res, __MetalogRow_mt)
	return res
end

--- @param metalog string
function Analysis_session(metalog)
	local files = {} -- map<string, MetalogRow[]>
	-- set is map<elem, bool>. if bool is true then elem exists
	local pkgs = {} -- map<string, set<string>>
	local nopkg = {} --            set<string>

	-- returns number of files in package and size of package
	-- nil is  returned upon errors
	--- @param pkgname string
	local function pkg_size(pkgname)
		local filecount, sz = 0, 0
		for filename in pairs(pkgs[pkgname]) do
			local rows = files[filename]
			-- normally, there should be only one row per filename
			-- if these rows are equal, there should be warning, but it
			-- does not affect size counting. if not, it is an error
			if #rows > 1 and not array_all_equal(rows) then
				return nil
			end
			local row = rows[1]
			if row.attrs.type == 'file' then
				sz = sz + tonumber(row.attrs.size)
			end
			filecount = filecount + 1
		end
		return filecount, sz
	end

	-- returns whether pkg has setuid files, whether pkg has setgid files
	--- @param pkgname string
	local function pkg_issetid(pkgname)
		local issetuid, issetgid = false, false
		for filename in pairs(pkgs[pkgname]) do
			-- considering duplicate files
			for _, row in ipairs(files[filename]) do
				local mode = tonumber(row.attrs.mode, 8)
				if mode & 2048 ~= 0 then issetuid = true end
				if mode & 1024 ~= 0 then issetgid = true end
			end
		end
		return issetuid, issetgid
	end

	local function pkg_report()
		local sb = {}
		for pkgname in sortedPairs(pkgs) do
			local numf, sz = pkg_size(pkgname)
			local issetuid, issetgid = pkg_issetid(pkgname)
			sb[#sb+1] = 'Package '..pkgname..':'
			if issetuid or issetgid then
				sb[#sb+1] = ''..table.concat({
					issetuid and ' setuid' or '',
					issetgid and ' setgid' or '' }, '')
			end
			sb[#sb+1] = '\n  number of files: '..(numf or '?')
				..'\n  total size: '..(sz or '?')
			sb[#sb+1] = '\n'
		end
		return table.concat(sb, '')
	end

	local fp, errmsg, errcode = io.open(metalog, 'r')
	if fp == nil then
		io.stderr:write('cannot open '..metalog..': '..errmsg..': '..errcode..'\n')
	end

	-- scan all lines and put file data into the arrays
	local lineno = 0
	for line in fp:lines() do
		local isinpkg = false
		lineno = lineno + 1
		-- skip lines begining with #
		if line:match('^%s*#') then goto continue end
		-- skip blank lines
		if line:match('^%s*$') then goto continue end

		local data = MetalogRow(line, lineno)
		files[data.filename] = files[data.filename] or {}
		table.insert(files[data.filename], data)

		if data.attrs.tags ~= nil then
			local pkgnames = data.attrs.tags:match('package=(.+)')
			if pkgnames ~= nil then
				for pkgname in pkgnames:gmatch('[^,]+') do
					pkgs[pkgname] = pkgs[pkgname] or {}
					pkgs[pkgname][data.filename] = true
				end
				isinpkg = true
			end
		end

		if not isinpkg then nopkg[data.filename] = true end

		::continue::
	end
	print(pkg_report())

	fp:close()

end

main(arg)
