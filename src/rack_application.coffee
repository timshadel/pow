PooledApplication = require './pooled_application'
nack              = require 'nack'
{join}            = require "path"
{bufferLines}     = require "./util"

module.exports = class RackApplication extends PooledApplication

  constructor: ->
    super
    @rackConfig = join(@root, "config.ru")

  createPool: (options) ->
    return @pool if @pool

    @pool = nack.createPool @rackConfig, options

    # Log the workers' stderr and stdout, and log each worker's
    # PID as it spawns and exits.
    bufferLines @pool.stdout, (line) => @logger.info line
    bufferLines @pool.stderr, (line) => @logger.warning line

    @pool.on "worker:spawn", (process) =>
      @logger.debug "nack worker #{process.child.pid} spawned"

    @pool.on "worker:exit", (process) =>
      @logger.debug "nack worker exited"

  sendToPool: (req, res, next, callback) ->
    req.proxyMetaVariables =
      SERVER_PORT: @configuration.dstPort.toString()
    try
      @pool.proxy req, res, (err) =>
        @quit() if err
        next err
    finally
      resume()
      callback?()
