--[[
	metalog.lua is a script that reads METALOG file created by pkgbase
	(make packages) and generates reports about the installed system
	and issues

	behaviour:

	for each package, if it has setuid/setgid files, its name will be appended
	with "setuid setgid".
	the number of files of the package and their total size is printed. if any
	files contain errors, the size may not be able to deduce

	if a same filename appears multiple times in the METALOG, and the
	*intersection* of their metadata names present in the METALOG have
	identical values, a warning is shown:
	warning: ./file exists in multiple locations identically: line 1475,30478
	(that means if line A has field "tags" but line B doesn't, if the remaning
	fields are equal, this warning is still shown)

	if a same filename appears multiple times in the METALOG, and the
	*intersection* of their metadata names present in the METALOG have
	different values, an error is shown:
	error: ./file exists in multiple locations and with different meta: line 8486,35592 off by "size"

	what's not impled:
	hardlink check
]]

function main(args)
	if #args == 0 then usage() end
	local filename = args[1]
	local s = Analysis_session(filename)
	io.write('--- PACKAGE REPORTS ---\n')
	io.write(s.pkg_report())
	local dupwarn, duperr = s.dup_report()
	io.write(dupwarn)
	io.write(duperr)
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

--- @param t table <T, U>
--- @param f function <U -> U>
function table_map(t, f)
    local res = {}
    for k, v in pairs(t) do res[k] = f(v) end
    return res
end

--- @class MetalogRow
-- a table contaning file's info, from a line content from METALOG file
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
	return res
end

-- check if an array of MetalogRows are equivalent. if not, the first field
-- that's different is returned secondly
--- @param rows MetalogRow[]
function metalogrows_all_equal(rows)
	local __eq = function(l, o)
		if l.filename ~= o.filename then return false end
		-- ignoring linenum in METALOG file as it's not relavant
		for k in pairs(l.attrs) do
			--if k == 'tags' then goto continue end
			if l.attrs[k] ~= o.attrs[k] and o.attrs[k] ~= nil then
				return false, k
			end
			--::continue::
		end
		return true
	end
	for _, v in ipairs(rows) do
		local bol, offby = __eq(v, rows[1])
		if not bol then return false, offby end
	end
	return true
end

--- @param metalog string
function Analysis_session(metalog)
	local files = {} -- map<string, MetalogRow[]>
	-- set is map<elem, bool>. if bool is true then elem exists
	local pkgs = {} -- map<string, set<string>>
	------ used to keep track of files not belonging to a pkg. not used so
	------ it is commented with -----
	------local nopkg = {} --            set<string>

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
			if #rows > 1 and not metalogrows_all_equal(rows) then
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

	-- returns a string describing package scan report
	--- @public
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

	-- returns a string describing duplicate file warnings,
	-- returns a string describing duplicate file errors
	--- @public
	local function dup_report()
		local warn, errs = {}, {}
		for filename, rows in sortedPairs(files) do
			if #rows == 1 then goto continue end
			local iseq, offby = metalogrows_all_equal(rows)
			if iseq then -- repeated line, just a warning
				warn[#warn+1] = 'warning: '..filename
					..' exists in multiple locations: line '
					..table.concat(
						table_map(rows, function(e) return e.linenum end), ',')
				warn[#warn+1] = '\n'
			else -- same filename, different metadata, an error
				errs[#errs+1] = 'error: '..filename
					..' exists in multiple locations and with different meta: line '
					..table.concat(
						table_map(rows, function(e) return e.linenum end), ',')
					..'. off by "'..offby..'"'
				errs[#errs+1] = '\n'
			end
			::continue::
		end
		return table.concat(warn, ''), table.concat(errs, '')
	end

	local fp, errmsg, errcode = io.open(metalog, 'r')
	if fp == nil then
		io.stderr:write('cannot open '..metalog..': '..errmsg..': '..errcode..'\n')
	end

	-- scan all lines and put file data into the arrays
	local lineno = 0
	for line in fp:lines() do
		-----local isinpkg = false
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
				------isinpkg = true
			end
		end

		-----if not isinpkg then nopkg[data.filename] = true end

		::continue::
	end

	fp:close()

	return {
		pkg_report = pkg_report,
		dup_report = dup_report
	}
end

main(arg)
