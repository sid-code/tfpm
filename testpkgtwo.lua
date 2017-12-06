
return function() 
  local file = assert(io.open("file", "w+"))
  file:write("hi")
  file:close()

  assert(lfs.mkdir("testdir"))
  assert(lfs.chdir("testdir"))

  local file = assert(io.open("cool_file", "w+"))
  file:write("woohoo")
  file:close()

  lfs.chdir("..")

  return {
    name = "testpkgtwo",
    version = "0.1",
    maintainer = "Morn",
    deps = ""
  }
end
