---@meta

---@class User
---@field id integer
---@field name string
local User = {}

---Return the user's id
---@param self User
---@return integer
function User:get_id() end

---Return the user's name
---@param self User
---@return string
function User:get_name() end

---Set the user's name
---@param self User
---@param name string
function User:set_name(name) end

---Greeting
---@param self User
---@return string
function User:greet() end

---@class user_module
local M = {}

---Creates a new User (backed by C userdata)
---@param id integer
---@param name string
---@return User
function M.new(id, name) end

return M
