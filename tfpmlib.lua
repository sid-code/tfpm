--[[

    tfpm, the TinyFugue Package Manager

]]

local sqlite3 = require("sqlite3")
local lfs = require("lfs")
local md5 = require("md5")
local inspect = require("inspect").inspect -- DELETE THIS

local logger = require("lib/log")
local Stepper = require("lib/stepper")

local deputils = require("tfpm/deps")

local tfpm_config = require("tfpm/config")

--------------------
----- DATABASE STUFF
--------------------
-- {{{

local tfpm_init_query = [[
CREATE TABLE IF NOT EXISTS packages (
  id INTEGER PRIMARY KEY ASC,
  name TEXT,
  version TEXT,
  maintainer TEXT,
  deps TEXT
);

CREATE TABLE IF NOT EXISTS pkgfiles (
  id INTEGER PRIMARY KEY ASC,
  ownerpkg TEXT,
  sum TEXT,
  path TEXT UNIQUE,
  mode TEXT,
  perms TEXT -- POSIX only
);
]]


-- note: db has to be closed at the end
local function create_new_db(filename)
  local db, err = sqlite3.open(filename)

  assert(db:exec(tfpm_init_query))

  return db
end

local function get_file_owner(db, file)
  local file_owner_stmt = assert(db:prepare({"path"}, [[ SELECT ownerpkg FROM pkgfiles WHERE path = :path ]]))
  file_owner_stmt:bind(file)
  for row in file_owner_stmt:rows() do
    return row.ownerpkg
  end

  return nil
end

local function package_files(db, package_name)
  local package_file_stmt = assert(db:prepare({"ownerpkg"}, [[ SELECT * FROM pkgfiles WHERE ownerpkg = :ownerpkg ]]))
  package_file_stmt:bind(package_name)
  return package_file_stmt:rows()
end

local function get_package_info(db, package_name)
  local package_info_stmt = assert(db:prepare({"name"}, [[ SELECT * FROM packages WHERE name = :name ]]))
  package_info_stmt:bind(package_name)

  for row in package_info_stmt:rows() do
    return row
  end
end

local function delete_package(db, package_name)
  local package_delete_stmt = assert(db:prepare({"name"}, [[ DELETE FROM packages WHERE name = :name ]]))
  local pkgfiles_delete_stmt = assert(db:prepare({"name"}, [[ DELETE FROM pkgfiles WHERE ownerpkg = :name ]]))
  package_delete_stmt:bind(package_name)
  pkgfiles_delete_stmt:bind(package_name)
  assert(package_delete_stmt:exec())
  assert(pkgfiles_delete_stmt:exec())
end
-- }}}

-----------------------
----- UTILITY FUNCTIONS
-----------------------
-- {{{
local function dirsplit(full_path, sep)
  if sep == nil then sep = "/" end
  local dir, file = full_path:match("(.+)" .. sep .. "([^/]+)$")
  if dir == nil then
    return "", full_path
  else
    return dir, file
  end
end

-- Returns the md5 32-char hex string
--
-- NOTE: currently this reads the entire file into memory. This might not be
-- possible with bigger files
local function md5file(file_path)
  local file = assert(io.open(file_path, "r"))
  local content = assert(file:read("*all"))
  file:close()

  return md5.sumhexa(content)
end

local function md5checkfile(file_path, md5sum)
  local check_against = md5file(file_path)
  return check_against == md5sum
end

-- Converts POSIX permission string into that chmod number
-- Example: rwxrwxrwx -> 777
local function permstrtonum(permstr)
  if permstr:len() ~= 9 then
    return nil, "permission string must have 9 chars"
  end
  
  -- converts each section of 3 characters into its number
  local function permpart(part)
    result = 0
    if part:sub(1,1) == "r" then
      result = result + 4
    end
    if part:sub(2,2) == "w" then
      result = result + 2
    end
    if part:sub(3,3) == "x" then
      result = result + 1
    end

    return result
  end

  return tostring(permpart(str:sub(1,3)))
      .. tostring(permpart(str:sub(4,6)))
      .. tostring(permpart(str:sub(7,9)))
end

-- }}}

-------------------------
----- FILE HANDLING STUFF
-------------------------
-- {{{
local function copy_file(oldname, newname)
  local file, source_content

  file = assert(io.open(oldname, "r"))
  source_content = assert(file:read("*all"))
  file:close()
  file = assert(io.open(newname, "w+"))
  assert(file:write(source_content))
  file:close()
end

local function split_files_dirs(list)
  local files = {}
  local dirs = {}

  for _, entity in ipairs(list) do
    if entity.mode == 'directory' then
      table.insert(dirs, entity)
    else
      table.insert(files, entity)
    end
  end

  return files, dirs
end

-- `list` is in the same format as returned by get_files_dirs (below)
local function copy_dirtree(srcdir, destdir, list)
  local total = #list
  local stepper = Stepper:new{max_steps = total}

  local files, dirs = split_files_dirs(list)

  table.sort(dirs, function (a, b) return a.name < b.name end)
  table.sort(files, function (a, b) return a.name < b.name end)

  -- first make the directories
  for _, entity in ipairs(dirs) do
    local dir = entity.name
    local dir_full_path = destdir .. "/" .. dir
    logger.info(stepper:stepstr("Creating directory " .. dir_full_path))
    lfs.mkdir(dir_full_path) -- TODO: check for errors here!!!
  end

  -- now make the files
  for _, entity in ipairs(files) do
    local file = entity.name
    local src = srcdir .. "/" .. file
    local dest = destdir .. "/" .. file

    local destpath, destfile = dirsplit(dest)

    logger.info(stepper:stepstr("Created file " .. dest))
    copy_file(src, dest)
  end

end

local function delete_dirtree_safe(db, location, list)
  local files, dirs = split_files_dirs(list)

  -- NOTE: here we sort in reverse, as when we're deleting the dir tree we need
  -- to start from the inside out
  table.sort(dirs, function (a, b) return a.path > b.path end)
  table.sort(files, function (a, b) return a.path > b.path end)

  -- first delete the files but ONLY if they're not modified
  for _, entity in ipairs(files) do
    local file = entity.path
    local real_file = location .. "/" .. file

    local sum_expected = entity.sum
    local sum_real = md5file(real_file)
    if sum_expected == sum_real or tfpm_config.hard_remove then
      local success, err
      if tfpm_config.hard_remove then
        local tmpname = os.tmpname()
        success, err = os.rename(real_file, tmpname)
        logger.info("Backed up modified file " .. real_file .. " to " .. tmpname)
      else
        success, err = os.remove(real_file)
      end
      if not success then
        logger.err("Couldn't delete file " .. real_file .. ": " .. err)
      end
    else
      logger.warn("Refusing to delete modified file: " .. real_file)
    end
      
  end

  -- now delete the directories
  for _, entity in ipairs(dirs) do
    local dir = entity.path
    local real_dir = location .. "/" .. dir

    local success, err = os.remove(dir)
    if not success then
      logger.err(err)
    end
  end
end

-- recursively places all files and directory in dir into the table `out`
-- each entry will be { name (string), mode = luafilesystem mode }
local function get_files_dirs(dir, out)
  for entity in lfs.dir(dir) do
    if entity ~= "." and entity ~= ".." then
      local full_path = dir .. "/" .. entity
      local attrs = lfs.attributes(full_path)
      local mode = attrs.mode
      local perms = attrs.permissions
      table.insert(out, { name = full_path:sub(3), mode = mode, perms = perms })
      if mode == "directory" then
        get_files_dirs(full_path, out)
      end
    end
  end
end

-- }}}

------------------------
----- PACKAGE MANAGEMENT
------------------------
-- {{{


--- HELPERS {{{
local function check_for_conflicts(db, files)
  local file_query_stmt = assert(db:prepare({"path"}, [[ SELECT path, ownerpkg FROM pkgfiles WHERE path = :path ]]))
  local conflicts = {}

  for _, file in ipairs(files) do
    file_query_stmt:bind(file.name)

    for row in file_query_stmt:rows() do
      table.insert(conflicts, row)
    end
  end

  return conflicts
end

local function insert_into_db(db, package_info, files)
  local package_insert_query_stmt = assert(db:prepare(
    {"name", "version", "maintainer", "deps"}, 
    [[ INSERT INTO packages (name, version, maintainer, deps) VALUES (:name, :version, :maintainer, :deps) ]]
  ))

  local file_insert_query_stmt = assert(db:prepare(
    {"ownerpkg", "sum", "path", "mode"},
    [[ INSERT INTO pkgfiles (ownerpkg, sum, path, mode) VALUES (:ownerpkg, :sum, :path, :mode) ]]
  ))

  package_insert_query_stmt:bind(
    package_info.name,
    package_info.version,
    package_info.maintainer,
    package_info.deps
  )


  package_insert_query_stmt:exec()

  local file_conflicts = {}

  for _, file in ipairs(files) do
    local name = file.name
    local is_dir = file.is_dir
    local mode = file.mode

    local sum
    if mode == "directory" then
      sum = ""
    else
      sum = md5file(name)
    end

    file_insert_query_stmt:bind(package_info.name, sum, name, mode)
    local success, err = pcall(assert, file_insert_query_stmt:exec())
    if not success and mode == "file" then
      -- note that directories are never conflicts
      table.insert(file_conflicts, name)
    end
  end


  return file_conflicts

end

local function query_local(db, package_query --[[ string for sqlite's LIKE ]])
  local package_list_stmt = assert(db:prepare({"name"}, [[ SELECT * FROM packages WHERE name LIKE :name ]]))
  package_list_stmt:bind(package_query)

  return package_list_stmt:rows()
end

-- This function parses the package row in the database into a more
-- computer-friendly structure.  Specifically, it calls
-- deputils.parse_version_string on the version and
-- deputils.parse_dependency_string on the dependency string.
local function parse_package_info(package_info)
  -- first copy the package info into a new table
  local new_package_info = {}
  for k, v in pairs(package_info) do
    new_package_info[k] = v
  end

  new_package_info.version = assert(deputils.parse_version_string(package_info.version))
  new_package_info.deps = assert(deputils.parse_dependency_string(package_info.deps))

  return new_package_info
end

-- Checks if dependencies are all met by packages (this doesn't use the db,
-- rather it is called by `check_dependencies_with(out)`.
local function check_dependencies(packages)
  local dependency_errors = {}

  for offender, err in deputils.check_dependencies(packages) do
    logger.err(deputils.dependency_error_tostring(offender, err))
    table.insert(dependency_errors, {offender = offender, err = err})
  end


  return dependency_errors
end

-- Checks if all dependencies are met with as if all packages in `new_packages`
-- were also installed. This is used before a package is installed to see if it
-- will actually work.
local function check_dependencies_with(db, new_packages)
  local packages = {}

  for _, new_package_info in ipairs(new_packages) do
    packages[new_package_info.name] = parse_package_info(new_package_info)
  end

  -- query_local(db, "%") returns all packages
  for package in query_local(db, "%") do
    packages[package.name] =  parse_package_info(package)
  end

  return check_dependencies(packages)
end

-- Same idea as above, but here removed_packages is just a list of strings. We
-- don't need the other info.
local function check_dependencies_without(db, removed_packages)
  local packages = {}

  -- query_local(db, "%") returns all packages
  for package in query_local(db, "%") do
    repeat -- ugly but lua has no continue.
      for _, removed in ipairs(removed_packages) do
        -- don't add if it's in `removed_packages` (continue)
        if package.name == removed then break end
      end
      packages[package.name] = parse_package_info(package)
    until true
  end

  -- now `packages` contains a list of packages with packages whose names were
  -- in `removed_packages` were not installed
  return check_dependencies(packages)
end


-- runs the script and collects the files it installs
local function make_package(package_script)
  local tmpdir = os.tmpname()
  local curdir = lfs.currentdir()
  local files = {}

  os.remove(tmpdir)
  assert(lfs.mkdir(tmpdir))

  local package_script_path, package_script_file = dirsplit(package_script)

  copy_file(package_script, tmpdir .. "/" .. package_script_file)

  lfs.chdir(tmpdir)
  local make_package = assert(loadfile(package_script_file))()
  os.remove(package_script_file)

  local success, result = pcall(make_package)
  if not success then
    logger.fatal("Failed to make package from script due to error " .. package_script)
  end

  local package_info = result

  lfs.chdir(tmpdir) -- because the package script might change dirs

  assert(package_info.name, "package has no name")
  assert(package_info.version, "package has no version")
  assert(package_info.maintainer, "package has no maintainer")
  assert(package_info.deps, "package has no deps declared (it should be an empty string if there are no dependencies)")

  get_files_dirs(".", files)

  lfs.chdir(curdir)
  
  return package_info, tmpdir, files
end

--- }}}

--- INSTALLING PACKAGES {{{
local function install_package_raw(db, package_info, tmpdir, files)
  local curdir = lfs.currentdir()

  local name = package_info.name
  local package_info_existing = get_package_info(db, package_info.name)

  if package_info_existing == nil then
    logger.info("Installing package " .. name)
  else
    local new_version = package_info.version
    local old_version = package_info_existing.version

    if deputils.compare_version_strings(new_version, old_version) == 1 then
      -- it's a newer version
    end

    logger.warn("Package " .. name .. " already installed.")
  end

  logger.info("Adding files to database and checking for conflicts...")

  lfs.chdir(tmpdir)
  local file_conflicts = insert_into_db(db, package_info, files)
  lfs.chdir(curdir)

  return file_conflicts
end

local function display_file_conflicts(db, name, file_conflicts)
  logger.warn("The package " .. name .. " tried to install the following files.")
  for _, conflict in ipairs(file_conflicts) do
    local ownerpkg = get_file_owner(db, conflict)
    if not ownerpkg then
      logger.fatal("This shouldn't have happened: file " .. conflict .. " doesn't have an owner. (" .. tostring(ownerpkg) .. ")")
    end

    logger.err("  " .. conflict .. " -- already owned by " .. ownerpkg)
  end
end

-- `packages` is a table array whose elements are
-- {
--   package_info = package_info,
--   tempdir = where the files are located,
--   files = what files are part of the package
-- }
--
-- basically the three return values of `make_package`
--
-- The reason this takes multiple packages is to allow installing a package and its dependencies without causing a dependency error 
local function install_packages(db, packages)

  logger.info("Resolving dependencies...")
  local package_infos = {}
  for name, package_desc in pairs(packages) do
    table.insert(package_infos, package_desc.package_info)
  end

  local dependency_errors = check_dependencies_with(db, package_infos)
  if #dependency_errors > 0 then
    if tfpm_config.no_deps then
      logger.warn("Dependencies not met, but continuing because of --no-deps.")
    else
      logger.fatal("Dependencies not met.")
    end
  end

  local conflicts = false
  db:exec[[ BEGIN TRANSACTION ]]
  for _, package_desc in ipairs(packages) do
    local name = package_desc.package_info.name
    local file_conflicts = install_package_raw(db, package_desc.package_info, package_desc.tmpdir, package_desc.files)

    if #file_conflicts > 0 then
      display_file_conflicts(db, name, file_conflicts)
      conflicts = true
    end
  end

  if conflicts then
    assert(db:exec[[ ROLLBACK ]])
    logger.fatal("Installation aborted due to file conflicts.")
  else
    db:exec[[ COMMIT ]]
  end


  local curdir = lfs.currentdir()
  logger.info("Copying files...")
  for name, package_desc in pairs(packages) do
    copy_dirtree(package_desc.tmpdir, curdir, package_desc.files)
  end

end

local function install_package_scripts(db, package_scripts)
  local packages = {}
  for _, script in ipairs(package_scripts) do
    local package_info, tmpdir, files = make_package(script)
    table.insert(packages, {package_info = package_info, tmpdir = tmpdir, files = files})
  end

  install_packages(db, packages)
end

--- }}}

--- UNINSTALLING PACKAGES {{{

local function uninstall_package(db, package_name)
  local files = {}
  for file in package_files(db, package_name) do
    table.insert(files, file)
  end

  delete_package(db, package_name)

  delete_dirtree_safe(db, ".", files)
end

local function uninstall_packages(db, package_names)
  -- first check if the packages exist
  for _, name in ipairs(package_names) do
    local info = get_package_info(db, name)
    if not info then
      logger.fatal("Package not installed: " .. name)
    end
  end

  local dependency_errors = check_dependencies_without(db, package_names)
  if #dependency_errors > 0 then
    if tfpm_config.no_deps then
      logger.warn("Dependencies not met, but continuing because of --no-deps.")
    else
      logger.fatal("Dependencies not met.")
    end
  end

  for _, name in ipairs(package_names) do
    uninstall_package(db, name)
  end

end

--- }}}

--- }}}

local tfpm = {
  config = tfpm_config,
  create_new_db = create_new_db,
  install_packages = install_packages,
  install_package_scripts = install_package_scripts,
  uninstall_packages = uninstall_packages,
  package_files = package_files,
  get_package_info = get_package_info
}

return tfpm

-- vim:fdm=marker
