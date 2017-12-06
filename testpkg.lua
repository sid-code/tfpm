local lfs = require("lfs")

return function()
  local file = assert(io.open("file", "w+"))
  file:write("hi")
  assert(lfs.mkdir("testdir"))
  assert(lfs.chdir("testdir"))
  file:close()

  local file = assert(io.open("file2", "w+"))
  file:write("hi")
  file:close()

  lfs.chdir("..")


  return {
    name = "testpkg",
    version = "0.1",
    maintainer = "Morn",
    deps = "testpkgtwo"
  }

end
