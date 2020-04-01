--[=[
	metalog_reader.lua is a script that reads METALOG file created by pkgbase
	(make packages) and generates reports about the installed system
	and issues

	the script accepts an mtree file in a format that's returned by
	'mtree -c | mtree -C'

	behaviour:

	under '-a' option for each package, if it has setuid/setgid files, its name will be
	appended with "setuid setgid".
	the number of files of the package and their total size is printed. if any
	files contain errors, the size may not be able to deduce

	if a same filename appears multiple times in the METALOG, and the
	*intersection* of their metadata names present in the METALOG have
	identical values, a warning is shown:
	warning: ./file repeated with same meta: line 1475,30478
	(that means if line A has field "size" but line B doesn't, if the remaining
	fields are equal, this warning is still shown)

	if a same filename appears multiple times in the METALOG, and the
	*intersection* of their metadata names present in the METALOG have
	different values, an error is shown:
	error: ./file exists in multiple locations and with different meta: line 8486,35592 off by "size"

	if an inode corresponds to multiple hardlinks, and these filenames have
	different name-values, an error is shown:
	error: entries point to the same inode but have different meta: ./file1,./file2 in line 2122,2120. off by "mode"

	synopsis:
		metalog_reader.lua [-a | -c | -p [-count] [-size] [...filters]] metalog-path

	some examples:

	`metalog_reader.lua -a METALOG`
		prints all scan results described above. this is the default option
	`metalog_reader.lua -c METALOG`
		only prints errors and warnings found in the file
	`metalog_reader.lua -p METALOG`
		only prints all the package names found in the file
	`metalog_reader.lua -p -count -size METALOG`
		prints all the package names, followed by number of files, followed by total size
	`metalog_reader.lua -p -size -fsetid METALOG`
		prints packages that has either setuid/setgid files, followed by the total size
	`metalog_reader.lua -p -fsetuid -fsetgid METALOG`
		prints packages that has both setuid and setgid files (if more than one filters are specified,
		they are composed using logic and)
	`metalog_reader.lua -p -count -size -fsetuid METALOG`
		prints packages that has setuid files, followed by number of files and total size
--]=]

function main(args)
	if #args == 0 then usage() end
	local filename
	local printall, checkonly, pkgonly
		= #args == 1, false, false
	local dcount, dsize, fuid, fgid, fid
		= false, false, false, false, false

	local i = 1
	while i <= #args do
		if args[i] == '-a' then
			printall = true
		elseif args[i] == '-c' then
			printall = false
			checkonly = true
		elseif args[i] == '-p' then
			printall = false
			pkgonly = true
			while i < #args do
				i = i+1
				if args[i] == '-count' then
					dcount = true
				elseif args[i] == '-size' then
					dsize = true
				elseif args[i] == '-fsetuid' then
					fuid = true
				elseif args[i] == '-fsetgid' then
					fgid = true
				elseif args[i] == '-fsetid' then
					fid = true
				else
					i = i-1
					break
				end
			end
		elseif args[i]:match('^%-') then
			io.stderr:write('Unknown argument '..args[i]..'.\n')
			usage()
		else
			filename = args[i]
		end
		i = i+1
	end

	if filename == nil then
		io.stderr:write('Missing filename.\n')
		usage()
	end

	local sess = Analysis_session(filename)

	if printall then
		io.write('--- PACKAGE REPORTS ---\n')
		io.write(sess.pkg_report_full())
		print_lints(sess)
	elseif checkonly then
		print_lints(sess)
	elseif pkgonly then
		io.write(sess.pkg_report_simple(dcount, dsize, {
			fuid and sess.pkg_issetuid or nil,
			fgid and sess.pkg_issetgid or nil,
			fid and sess.pkg_issetid or nil
		}))
	else
		io.stderr:write('This text should not display.')
		usage()
	end
end

function usage()
	io.stderr:write('usage: '..arg[0].. ' [-a | -c | -p [-count] [-size] [...filters]] metalog-path \n'
		..'available filters: [-fsetuid] [-fsetgid] [-fsetid]\n')
	os.exit(1)
end

--- @param sess Analysis_session
function print_lints(sess)
	local dupwarn, duperr = sess.dup_report()
	io.write(dupwarn)
	io.write(duperr)
	local inodewarn, inodeerr = sess.inode_report()
	io.write(inodewarn)
	io.write(inodeerr)
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
--- @param ignore_name boolean
--- @param ignore_tags boolean
function metalogrows_all_equal(rows, ignore_name, ignore_tags)
	local __eq = function(l, o)
		if not ignore_name and l.filename ~= o.filename then
			return false, 'filename'
		end
		-- ignoring linenum in METALOG file as it's not relavant
		for k in pairs(l.attrs) do
			if ignore_tags and k == 'tags' then goto continue end
			if l.attrs[k] ~= o.attrs[k] and o.attrs[k] ~= nil then
				return false, k
			end
			::continue::
		end
		return true
	end
	for _, v in ipairs(rows) do
		local bol, offby = __eq(v, rows[1])
		if not bol then return false, offby end
	end
	return true
end

--- @class Analysis_session
--- @param metalog string
function Analysis_session(metalog)
	local files = {} -- map<string, MetalogRow[]>
	-- set is map<elem, bool>. if bool is true then elem exists
	local pkgs = {} -- map<string, set<string>>
	----- used to keep track of files not belonging to a pkg. not used so
	----- it is commented with -----
	-----local nopkg = {} --            set<string>

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

	--- @param pkgname string
	--- @param mode number
	local function pkg_ismode(pkgname, mode)
		for filename in pairs(pkgs[pkgname]) do
			for _, row in ipairs(files[filename]) do
				if tonumber(row.attrs.mode, 8) & mode ~= 0 then
					return true
				end
			end
		end
		return false
	end

	--- @param pkgname string
	--- @public
	local function pkg_issetuid(pkgname)
		return pkg_ismode(pkgname, 2048)
	end

	--- @param pkgname string
	--- @public
	local function pkg_issetgid(pkgname)
		return pkg_ismode(pkgname, 1024)
	end

	--- @param pkgname string
	--- @public
	local function pkg_issetid(pkgname)
		return pkg_issetuid(pkgname) or pkg_issetgid(pkgname)
	end

	-- sample return:
	-- { [*string]: { count=1, size=2, issetuid=true, issetgid=true } }
	local function pkg_report_helper_table()
		local res = {}
		for pkgname in pairs(pkgs) do
			res[pkgname] = {}
			res[pkgname].count,
			res[pkgname].size = pkg_size(pkgname)
			res[pkgname].issetuid = pkg_issetuid(pkgname)
			res[pkgname].issetgid = pkg_issetgid(pkgname)
		end
		return res
	end

	-- returns a string describing package scan report
	--- @public
	local function pkg_report_full()
		local sb = {}
		for pkgname, v in sortedPairs(pkg_report_helper_table()) do
			sb[#sb+1] = 'Package '..pkgname..':'
			if v.issetuid or v.issetgid then
				sb[#sb+1] = ''..table.concat({
					v.issetuid and ' setuid' or '',
					v.issetgid and ' setgid' or '' }, '')
			end
			sb[#sb+1] = '\n  number of files: '..(v.count or '?')
				..'\n  total size: '..(v.size or '?')
			sb[#sb+1] = '\n'
		end
		return table.concat(sb, '')
	end

	--- @param have_count boolean
	--- @param have_size boolean
	--- @param filters function[]
	--- @public
	-- returns a string describing package size report.
	-- sample: "mypackage 2 2048"* if both booleans are true
	local function pkg_report_simple(have_count, have_size, filters)
		filters = filters or {}
		local sb = {}
		for pkgname, v in sortedPairs(pkg_report_helper_table()) do
			local pred = true
			-- doing a foldl to all the function results with (and)
			for _, f in pairs(filters) do pred = pred and f(pkgname) end
			if pred then
				sb[#sb+1] = pkgname..table.concat({
					have_count and (' '..(v.count or '?')) or '',
					have_size and (' '..(v.size or '?')) or ''}, '')
					..'\n'
			end
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
					..' repeated with same meta: line '
					..table.concat(
						table_map(rows, function(e) return e.linenum end), ',')
				warn[#warn+1] = '\n'
			elseif not metalogrows_all_equal(rows, false, true) then
			-- same filename (possibly different tags), different metadata, an error
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

	-- returns a string describing warnings of found hard links
	-- returns a string describing errors of found hard links
	--- @public
	local function inode_report()
		-- obtain inodes of filenames
		local attributes = require('lfs').attributes
		local inm = {} -- map<number, string[]>
		local unstatable = 0
		for filename in pairs(files) do
			-- i only took the first row of a filename,
			-- and skip links and folders
			if files[filename][1].attrs.type ~= 'file' then
				goto continue
			end
			-- make ./xxx become /xxx so that we can stat
			filename = filename:sub(2)
			local fs = attributes(filename)
			if fs == nil then
				unstatable = unstatable + 1
				goto continue
			end
			local inode = fs.ino
			inm[inode] = inm[inode] or {}
			-- add back the dot prefix
			table.insert(inm[inode], '.'..filename)
			::continue::
		end

		local warn, errs = {}, {}
		for _, filenames in pairs(inm) do
			if #filenames == 1 then goto continue end
			-- i only took the first row of a filename
			local rows = table_map(filenames, function(e)
				return files[e][1]
			end)
			local iseq, offby = metalogrows_all_equal(rows, true, true)
			if not iseq then
				errs[#errs+1] = 'error: '
					..'entries point to the same inode but have different meta: '
					..table.concat(filenames, ',')..' in line '
					..table.concat(
						table_map(rows, function(e) return e.linenum end), ',')
					..'. off by "'..offby..'"'
				errs[#errs+1] = '\n'
			end
			::continue::
		end

		if unstatable > 0 then
			warn[#warn+1] = 'note: skipped checking inodes for '..unstatable..' entries\n'
		end

		return table.concat(warn, ''), table.concat(errs, '')
	end

	local fp, errmsg, errcode = io.open(metalog, 'r')
	if fp == nil then
		io.stderr:write('cannot open '..metalog..': '..errmsg..': '..errcode..'\n')
	end

	-- scan all lines and put file data into the dictionaries
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
			local segs = data.attrs.tags:match('package=(.+)')
			local mistake = data.attrs.tags:match('(.+),package')
			if segs ~= nil then
				local pkgname = segs:gsub(',', '-')
				pkgs[pkgname] = pkgs[pkgname] or {}
				pkgs[pkgname][data.filename] = true
				------isinpkg = true
			end
		end
		-----if not isinpkg then nopkg[data.filename] = true end
		::continue::
	end

	fp:close()

	return {
		pkg_issetuid = pkg_issetuid,
		pkg_issetgid = pkg_issetgid,
		pkg_issetid = pkg_issetid,
		pkg_report_full = pkg_report_full,
		pkg_report_simple = pkg_report_simple,
		dup_report = dup_report,
		inode_report = inode_report
	}
end

main(arg)
