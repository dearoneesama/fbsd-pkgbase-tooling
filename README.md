`metalog.lua` is a script that reads METALOG file created by pkgbase
(make packages) and generates reports about the installed system
and issues

the script accepts an mtree file in a format that's returned by
`mtree -c | mtree -C`

behaviour:

for each package, if it has setuid/setgid files, its name will be appended
with "setuid setgid".
the number of files of the package and their total size is printed. if any
files contain errors, the size may not be able to deduce

if a same filename appears multiple times in the METALOG, and the
*intersection* of their metadata names present in the METALOG have
identical values, a warning is shown:
```
warning: ./file exists in multiple locations identically: line 1475,30478
```
(that means if line A has field "tags" but line B doesn't, if the remaining
fields are equal, this warning is still shown)

if a same filename appears multiple times in the METALOG, and the
*intersection* of their metadata names present in the METALOG have
different values, an error is shown:
```
error: ./file exists in multiple locations and with different meta: line 8486,35592 off by "size"
```

if an inode corresponds to multiple hardlinks, and these filenames have
different name-values, an error is shown:
```
error: entries point to the same inode but have different meta: ./file1,./file2 in line 2122,2120. off by "mode"
```