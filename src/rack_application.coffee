PooledApplication = require './pooled_application'
nack              = require 'nack'
{join}            = require "path"

module.exports = class RackApplication extends PooledApplication

  constructor: ->
    super
    @rackConfig = join(@root, "config.ru")

  createPool: (options) ->
    nack.createPool @rackConfig, options