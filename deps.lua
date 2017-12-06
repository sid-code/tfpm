-- dependency management and utilities

-- version format: positive integers separated by dots.
-- valid: 1.2.3  0.0.0 0.1.1 0.243.1.52034.2142
-- invalid: 1.2.-5  1.6.3a 
local function parse_version_string(vstr)
  local nums = {}
  for numstr in vstr:gmatch("[^.]*") do
    local num = tonumber(numstr)
    if num then
      table.insert(nums, num)
    else
      return nil, "invalid version string: " .. vstr
    end
  end

  return nums
end

-- compares two versions v1,v2 (int arrays)
-- if v1 is newer than v2, then returns 1
-- if v1 equals v2, then returns 0
-- if v1 is older than v2, then returns -1
local function compare_versions(v1, v2)
  local size1 = #v1
  local size2 = #v2
  local min_size = math.min(size1, size2)
  local i
  for i = 1, min_size do
    if v1[i] > v2[i] then return 1 end
    if v1[i] < v2[i] then return -1 end
  end

  if size1 > size2 then return 1 end
  if size1 < size2 then return -1 end

  return 0
end

-- shortcut for the above function
local function compare_version_strings(vs1, vs2)
  local v1, err1 = parse_version_string(vs1)
  local v2, err2 = parse_version_string(vs2)

  if v1 == nil then return nil, err1 end
  if v2 == nil then return nil, err2 end

  return compare_versions(v1, v2)
end

local dep_types = { "[@=]", ">=", "<=", ">", "<" }
dep_types.eq = dep_types[1]
dep_types.gte = dep_types[2]
dep_types.lte = dep_types[3]
dep_types.gt = dep_types[4]
dep_types.lt = dep_types[5]

local function dep_type_to_english(dep_type)
  if dep_type == dep_types.eq then
    return " at "
  else
    return dep_type
  end
end

local function parse_single_dependency(dep)
  local pkgname, version

  for _, depmod in ipairs(dep_types) do
    -- full syntax
    pkgname, version = dep:match("^([%w-_]+)" .. depmod .. "(.+)$")

    if pkgname and version then
      return {name = pkgname, version = version, relation = depmod}
    end

    -- just package name
    pkgname = dep:match("^[%w-_]+$")
    if pkgname then
      return {name = pkgname, version = "0", relation = dep_types.gt}
    end
  end

  return nil, "malformed dependency string: " .. dep

end

-- versions are passed in as integer arrays: {1, 2, 3}, not strings: "1.2.3"
local function check_single_dependency(required_version, existing_version, relation)
  local comparison = compare_versions(required_version, existing_version)

  if comparison == 0 and (relation == dep_types.eq or relation == dep_types.lte or relation == dep_types.gte) then
    return true
  elseif comparison == 1 and (relation == dep_types.lt or relation == dep_types.lte) then
    return true
  elseif comparison == -1 and (relation == dep_types.gt or relation == dep_types.gte) then
    return true
  end

  return false

end

local function parse_dependency_string(depstr)
  local dependencies = {}
  local errors = {}

  for part in depstr:gmatch("[^%s]+") do
    local dep, err = parse_single_dependency(part)

    if dep then
      dep.version = parse_version_string(dep.version)
      table.insert(dependencies, dep)
    else
      table.insert(errors, err)
    end
  end

  if #errors > 0 then
    return nil, "dependency parsing errors:\n  " .. table.concat(errors, "\n  ")
  end

  return dependencies
end

-- packages is a table array where each element is
-- {
--   name = "",
--   version = <version>,
--   deps = {dependency1, dependency2, ...}
-- }
--
-- version is represented by the return value of `parse_version_string`
--
-- dependencies are represented by the return value of
-- `parse_dependency_string`

local function check_dependencies(packages)
  return coroutine.wrap(function()
    for _, info in pairs(packages) do
      local name = info.name
      local deps = info.deps
      for _, dep in ipairs(deps) do
        local dep_name = dep.name
        local dep_version = dep.version
        local dep_relation = dep.relation

        local required_package = packages[dep_name]
        if required_package then
          local met = check_single_dependency(dep_version, required_package.version, dep_relation)
          if not met then
            coroutine.yield(name, dep)
          end
        else
          coroutine.yield(name, dep)
        end
      end
    end
  end)
end

local function dependency_error_tostring(package_name, failed_dep)
  local result = "Failed dependency: "
  result = result .. "package \"" .. package_name .. "\" demands \""
                  .. failed_dep.name .. "\""
                  .. dep_type_to_english(failed_dep.relation)
                  .. table.concat(failed_dep.version, ".")
  return result

end

local function test_dependency_parser()
  local inspect = require("inspect").inspect
  local dep = assert(parse_dependency_string("test"))
  print(inspect(dep))
  
end

local function test_dependency_checker()
  local inspect = require("inspect").inspect

  local packages = {
    a = {
      version = parse_version_string("1.2.0"),
      deps = parse_dependency_string("b>=0.1.0 c@2.1.0")
    },

    b = {
      version = parse_version_string("2.5"),
      deps = parse_dependency_string("c<1.0.0")
    },

    c = {
      version = parse_version_string("0.9"),
      deps = parse_dependency_string("a@1.2.0") -- circular dependency
    }
  }

  local failed_deps = check_dependencies(packages)

  for p, f in failed_deps do
    print(dependency_error_tostring(p, f))
  end
end

return {
  parse_version_string = parse_version_string,
  compare_versions = compare_versions,
  compare_version_strings = compare_version_strings,
  parse_dependency_string = parse_dependency_string,
  check_dependencies = check_dependencies,
  dependency_error_tostring = dependency_error_tostring
}

