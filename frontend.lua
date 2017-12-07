

local sqlite3 = require("sqlite3")
local argparse = require("argparse")

local tfpm = require("tfpm/tfpmlib")
local moosplit = require("lib/moosplit")


local function err_handler(err)
  if tfpm.config.debug then
    print(debug.traceback(err))
  end
end

local function set_config_soft(config_option, value)
  if tfpm.config[config_option] == nil then
    tfpm.config[config_option] = value
  end
end

local frontend = {}

function frontend.install(db, options)
  tfpm.install_package_scripts(db, options.packages)
end

function frontend.remove(db, options)
  tfpm.uninstall_packages(db, options.packages);
end

function frontend.query(db, options)
end

local function main(argstr)
  local parser = argparse() {
    name = "tfpm",
    description = "TinyFugue package manager",
    epilogue = "TBA",
  }

  parser:command_target("command")

  local install = parser:command("install i")
  install:argument("packages"):args("+"):description("package scripts to install")
  install:flag("-n --no-deps"):description("ignore dependencies and install anyways")
  install:flag("-f --force"):description("force install (overwrite file conflicts) [NOT SUPPORTED YET]")

  local remove = parser:command("remove r")
  remove:argument("packages"):args("+"):description("packages to remove")
  remove:flag("-n --no-deps"):description("ignore dependencies and uninstall anyways")
  remove:flag("-h --hard"):description("remove files even if they've been changed")

  local query = parser:command("query q"):description("query packages - search for them or info about them")
  query:flag("-f --files"):description("get file list")
  query:flag("-i --info"):description("get package_info")
  query:argument("packages"):args("+"):description("packages to query")

  local options = parser:parse(argstr:moosplit())
  set_config_soft("hard_remove", options.hard)
  set_config_soft("force", options.force)
  set_config_soft("no_deps", options.no_deps)

  local db = tfpm.create_new_db(tfpm.config.db)
  frontend[options.command](db, options)

  return options
end

local inspect = require 'inspect'.inspect
print(inspect(main(table.concat(arg, " "))))
