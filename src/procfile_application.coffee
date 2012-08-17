PooledApplication = require './pooled_application'
norman            = require 'norman'
{join}            = require "path"

module.exports = class ProcfileApplication extends PooledApplication

  constructor: ->
    super
    @procfile = join(@root, "Procfile")
    @server   = norman.createServer(@procfile)
    @server.runOnce = false

  # Objects returned by this method must honor `runOnce` and
  # respond to `quit`.
  createPool: (options) ->
    @server.spawn options, =>
      @apps = @server?.formation?.pools?['web']
    @server

  sendToPool: (req, res, next, resume, callback) ->
    port = @apps?[0]?.port
    return next() unless port?

    try
      req.pow.url = "http://localhost:#{port}"
      console.log "Procfile app set req.pow.url = #{req.pow.url}"

      # Bounce the entire formation if we need to...useful?
      if @server.runOnce
        original_end = res.end
        res.end = (args...) ->
          @server.quit =>
            @server.spawn
          original_end(args...)

      next()

    finally
      resume()
      callback?()


