# The `ForemanApplication` class is responsible for managing a set of
# [Foreman](http://ddollar.github.com/foreman)-started applications
# Incoming HTTP requests are dispatched to each of the web app processes
# in a manner that roughly resembles Heroku's routing.
#
#  > "[Heroku's] routing mesh only routes traffic to processes named web.N"
#  > - http://devcenter.heroku.com/articles/oneoff-admin-ps
#
#  > "If you have more than one web dyno, the routing mesh will load
#  > balance across them using a standard random selection algorithm."
#  >  - http://devcenter.heroku.com/articles/http-routing
#
# Before launching Foreman, Pow executes the `.powrc` and `.powenv`
# scripts if they're present in the application root. You can use these
# to specify alternate `env` and `procfile` files to be passed to
# Foreman.
#
# You are encouraged to use Foreman constructs such as `.env` and
# `.foreman` to specify custom environment variables, or to set
# concurrency options.
#
# Because Pow may well be running multiple Foreman applications, all of
# which could specify the same port number, Pow will choose the base
# port for every Foreman [process
# formation](http://devcenter.heroku.com/articles/scaling#process_format
# ion). Foreman will choose the port numbers for subsequent processes.
#
# If [rvm](http://rvm.beginrescueend.com/) is installed and an `.rvmrc`
# file is present in the application's root, Pow will load both before
# launching Foreman. This makes it easy to make sure that you use
# specific Ruby & Foreman versions (e.g. `rvm use 1.9.2@foreman`).
#
# Foreman will gracefully shutdown all of its processes once any one of
# them dies. If you wish to reload processes on demand, then you should
# alter the commands used to launch them in your `Procfile` (and consider
# adding separate `Procfile`s per environment).

async = require "async"
fs    = require "fs"
net   = require "net"

{bufferLines, pause, sourceScriptEnv, PortChecker} = require "./util"
{join, exists, basename} = require "path"
{spawn, exec}            = require 'child_process'
{HttpProxy}              = require "http-proxy"

module.exports = class ForemanApplication
  # Create a `ForemanApplication` for the given configuration and
  # root path. The application begins life in the uninitialized
  # state.
  constructor: (@configuration, @root) ->
    @logger = @configuration.getLogger join "apps", basename @root
    @procfile = @configuration.procfile
    @readyCallbacks = []
    @quitCallbacks  = []
    @statCallbacks  = []
  
  changeState: (state) ->
    @logger.debug "ForemanApplication #{@} changing from #{@state} to #{state}"
    @state = state

  # Queue `callback` to be invoked when the application becomes ready,
  # then start the initialization process. If the application's state
  # is ready, the callback is invoked immediately.
  ready: (callback) ->
    if @state is "ready"
      callback()
    else
      @readyCallbacks.push callback
      @initialize()

  # Tell the application to quit and queue `callback` to be invoked
  # when all workers have exited. If the application has already quit,
  # the callback is invoked immediately.
  quit: (callback) ->
    if @state
      @quitCallbacks.push callback if callback
      @terminate()
    else
      callback?()

  # Stat `tmp/restart.txt` in the application root and invoke the
  # given callback with a single argument indicating whether or not
  # the file has been touched since the last call to
  # `queryRestartFile`.
  queryRestartFile: (callback) ->
    fs.stat join(@root, "tmp/restart.txt"), (err, stats) =>
      if err
        @mtime = null
        callback false
      else
        lastMtime = @mtime
        @mtime = stats.mtime.getTime()
        callback lastMtime isnt @mtime

  # Collect environment variables from `.powrc` and `.powenv`, in that
  # order, if present. The idea is that `.powrc` files can be checked
  # into a source code repository for global configuration, leaving
  # `.powenv` free for any necessary local overrides.
  loadScriptEnvironment: (env, callback) ->
    async.reduce [".powrc", ".envrc", ".powenv"], env, (env, filename, callback) =>
      exists script = join(@root, filename), (scriptExists) ->
        if scriptExists
          sourceScriptEnv script, env, callback
        else
          callback null, env
    , callback

  # If `.rvmrc` and `$HOME/.rvm/scripts/rvm` are present, load rvm,
  # source `.rvmrc`, and invoke `callback` with the resulting
  # environment variables. If `.rvmrc` is present but rvm is not
  # installed, invoke `callback` without sourcing `.rvmrc`.
  loadRvmEnvironment: (env, callback) ->
    exists script = join(@root, ".rvmrc"), (rvmrcExists) =>
      if rvmrcExists
        exists rvm = @configuration.rvmPath, (rvmExists) ->
          if rvmExists
            before = "source '#{rvm}' > /dev/null"
            sourceScriptEnv script, env, {before}, callback
          else
            callback null, env
      else
        callback null, env

  # Stat `tmp/restart.txt` to cache its mtime, then load the
  # application's full environment from `.powrc`, `.powenv`, and
  # `.rvmrc`.
  loadEnvironment: (callback) ->
    @queryRestartFile =>
      @loadScriptEnvironment null, (err, env) =>
        if err then callback err
        else @loadRvmEnvironment env, (err, env) =>
          if err then callback err
          else
            # .powenv can override the choice of Procfile
            @procfile = env?.POW_PROCFILE ? @procfile
            callback null, env

  # Begin the initialization process if the application is in the
  # uninitialized state. (If the application is terminating, queue a
  # call to `initialize` after the `ruby: foreman master` child process
  # has exited.)
  initialize: ->
    if @state
      if @state is "terminating"
        @quit => @initialize()
      return

    @changeState "initializing"

    # Load the application's environment. If an error is raised or
    # either of the environment scripts exits with a non-zero status,
    # reset the application's state and log the error.
    @loadEnvironment (err, env) =>
      if err
        @changeState null
        @logger.error err.message
        @logger.error "stdout: #{err.stdout}"
        @logger.error "stderr: #{err.stderr}"

      # Set the application's state to ready.
      else
        @spawning = {}
        @webProcesses = {}
        @webProcessCount = 0
        @spawnedCount = 0
        @readyCount = 0
        
        # Let the system select a port, then we'll use that as Foreman's base port
        tmpServer = new net.Server
        basePort = undefined

        tmpServer.on 'close', =>
          @foreman = spawn 'foreman', ['start', '-f', @procfile, '-p', basePort],
            cwd:  @root
            env:  env

          @logger.info "forman master #{@foreman.pid} spawned"

          # Log the workers' stderr and stdout, and capture each worker's
          # PID and port as it spawns and exits.
          bufferLines @foreman.stdout, (line) =>
            @logger.info line
            # Change to 'ready' when all Foreman processes have launched
            @captureForemanPorts line if @state is "initializing"

          bufferLines @foreman.stderr, (line) => @logger.warning line

          @foreman.on 'exit', (code, signal) =>
            @logger.debug "foreman master exited with code #{code} & signal #{signal}; #{@quitCallbacks.length} callbacks to go..."
            @foreman = null
            @changeState null
            quitCallback() for quitCallback in @quitCallbacks
            @quitCallbacks = []   

        tmpServer.listen 0, =>
          basePort = tmpServer.address().port
          tmpServer.close()


  captureForemanPorts: (line) ->
    portInUseMatch = /.* (web\.[0-9]+).*EADDRINUSE, Address already in use/(line)
    if portInUseMatch
      err = new Error("Port assigned to #{portInUseMatch[1]} in use already")
      @changeState "ready"
      readyCallback(err) for readyCallback in @readyCallbacks
      @readyCallbacks = []   
      @quit()

    countMatch = /Launching ([0-9]+) ([\w]+) process.*/(line)
    if countMatch
      if countMatch[2] == "web"
        @webProcessCount = Number(countMatch[1])
    
    if @webProcessCount == 0 and /.*started with pid.*/(line)
      # For some reason, this event needs some time before killing the master kills all procs
      setTimeout =>
        err = new Error("Foreman didn't start any `web` processes. Check your Procfile.")
        @changeState "ready"
        readyCallback(err) for readyCallback in @readyCallbacks
        @readyCallbacks = []   
        @quit()
      , 50
      
    readyMatch = /.* (web\.[0-9]+).*started with pid ([0-9]+) and port ([0-9]+)/(line)
    if readyMatch
      @spawning[readyMatch[1]] or= {}
      @spawning[readyMatch[1]].pid = Number(readyMatch[2])
      @spawning[readyMatch[1]].port = Number(readyMatch[3])
      @spawning[readyMatch[1]].name = readyMatch[1]
      @spawnedCount++
  
    if @spawnedCount > 0 and @spawnedCount == @webProcessCount
      @changeState "spawning"
      @checkPorts()

  # Start checking to see if the expected ports are accepting connections.
  checkPorts: ->
    return unless @state is "spawning"
    @webProcesses = {}

    # Try all workers in parallel
    for name, process of @spawning
      detector = new PortChecker name, process.port
      detector.on 'ready', (name) =>
        @webProcesses[name] = @spawning[name]
        delete @spawning[name]
        @readyCount++
        @logger.info "#{@readyCount} of #{@webProcessCount} workers ready"
        if @readyCount == @webProcessCount
          @changeState "ready"
          readyCallback() for readyCallback in @readyCallbacks
          @readyCallbacks = []

      detector.on 'notAvailable', (name) =>
        err = new Error("Timed out waiting for port #{@spawning[name].port} to be available.")
        @changeState "ready"
        readyCallback(err) for readyCallback in @readyCallbacks
        @readyCallbacks = []   
        @quit()

        
  # Begin the termination process. (If the application is initializing,
  # wait until it is ready before shutting down.)
  terminate: ->
    if @state is "initializing"
      @ready =>
        @terminate()

    else if @state is "ready"
      if @foreman
        @changeState "terminating"
        @logger.debug "Sending SIGTERM to #{@foreman.pid}"
        @foreman.kill 'SIGTERM'

        # Setup a timer to send SIGTERM if the process doesn't
        # gracefully quit after 3 seconds.
        timeout = setTimeout =>
          if @state is 'terminating'
            @logger.debug "Sending SIGKILL to #{@foreman.pid}"
            @foreman.kill 'SIGKILL'
        , 3000

  # Handle an incoming HTTP request. Wait until the application is in
  # the ready state, restart the workers if necessary, then proxy the
  # request to the Foreman child processes. If there's a problem with
  # the proxy request, reset the application.
  handle: (req, res, next, callback) ->
    resume = pause req
    @ready (err) =>
      return next err if err
      @restartIfNecessary =>
        req.proxyMetaVariables =
          SERVER_PORT: @configuration.dstPort.toString()
        try   
          proxy = new HttpProxy()
          proxy.on 'proxyError', (err, req, res) ->
            next(err)
        
          index = Math.ceil(Math.random() * @webProcessCount)
          process = @webProcesses["web.#{index}"]                                 
          proxy.proxyRequest req, res, {host: 'localhost', port: process.port}
        finally
          resume()
          callback?()

  # Terminate the application, re-initialize it, and invoke the given
  # callback when the application's state becomes ready.
  restart: (callback) ->
    @quit =>
      @ready callback

  # Restart the application if `tmp/restart.txt` has been touched
  # since the last call to this function.
  restartIfNecessary: (callback) ->
    @queryRestartFile (mtimeChanged) =>
      if mtimeChanged
        @logger.debug "Restarting..."
        @restart callback
      else
        callback()
