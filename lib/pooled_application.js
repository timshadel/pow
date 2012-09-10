// Generated by CoffeeScript 1.3.3
(function() {
  var PooledApplication, async, basename, bufferLines, exists, fs, join, pause, resolve, sourceScriptEnv, _ref, _ref1;

  async = require("async");

  fs = require("fs");

  _ref = require("./util"), bufferLines = _ref.bufferLines, pause = _ref.pause, sourceScriptEnv = _ref.sourceScriptEnv;

  _ref1 = require("path"), join = _ref1.join, exists = _ref1.exists, basename = _ref1.basename, resolve = _ref1.resolve;

  module.exports = PooledApplication = (function() {

    function PooledApplication(configuration, root, firstHost) {
      this.configuration = configuration;
      this.root = root;
      this.firstHost = firstHost;
      this.logger = this.configuration.getLogger(join("apps", basename(this.root)));
      this.readyCallbacks = [];
      this.quitCallbacks = [];
      this.statCallbacks = [];
    }

    PooledApplication.prototype.ready = function(callback) {
      if (this.state === "ready") {
        return callback();
      } else {
        this.readyCallbacks.push(callback);
        return this.initialize();
      }
    };

    PooledApplication.prototype.quit = function(callback) {
      if (this.state) {
        if (callback) {
          this.quitCallbacks.push(callback);
        }
        return this.terminate();
      } else {
        return typeof callback === "function" ? callback() : void 0;
      }
    };

    PooledApplication.prototype.queryRestartFile = function(callback) {
      var _this = this;
      return fs.stat(join(this.root, "tmp/restart.txt"), function(err, stats) {
        var lastMtime;
        if (err) {
          _this.mtime = null;
          return callback(false);
        } else {
          lastMtime = _this.mtime;
          _this.mtime = stats.mtime.getTime();
          return callback(lastMtime !== _this.mtime);
        }
      });
    };

    PooledApplication.prototype.setPoolRunOnceFlag = function(callback) {
      var _this = this;
      if (!this.statCallbacks.length) {
        exists(join(this.root, "tmp/always_restart.txt"), function(alwaysRestart) {
          var statCallback, _i, _len, _ref2;
          _this.pool.runOnce = alwaysRestart;
          _ref2 = _this.statCallbacks;
          for (_i = 0, _len = _ref2.length; _i < _len; _i++) {
            statCallback = _ref2[_i];
            statCallback();
          }
          return _this.statCallbacks = [];
        });
      }
      return this.statCallbacks.push(callback);
    };

    PooledApplication.prototype.loadScriptEnvironment = function(env, callback) {
      var _this = this;
      return async.reduce([".powrc", ".envrc", ".powenv"], env, function(env, filename, callback) {
        var script;
        return exists(script = join(_this.root, filename), function(scriptExists) {
          if (scriptExists) {
            console.log("Found " + script + ", have env:", env);
            return sourceScriptEnv(script, env, callback);
          } else {
            return callback(null, env);
          }
        });
      }, callback);
    };

    PooledApplication.prototype.loadRvmEnvironment = function(env, callback) {
      var script,
        _this = this;
      return exists(script = join(this.root, ".rvmrc"), function(rvmrcExists) {
        var rvm;
        if (rvmrcExists) {
          return exists(rvm = _this.configuration.rvmPath, function(rvmExists) {
            var before, libexecPath;
            if (rvmExists) {
              libexecPath = resolve("" + __dirname + "/../libexec");
              before = ("'" + libexecPath + "/pow_rvm_deprecation_notice' '" + [_this.firstHost] + "'\nsource '" + rvm + "' > /dev/null").trim();
              return sourceScriptEnv(script, env, {
                before: before
              }, callback);
            } else {
              return callback(null, env);
            }
          });
        } else {
          return callback(null, env);
        }
      });
    };

    PooledApplication.prototype.loadEnvironment = function(callback) {
      var _this = this;
      return this.queryRestartFile(function() {
        return _this.loadScriptEnvironment(_this.configuration.env, function(err, env) {
          if (err) {
            return callback(err);
          } else {
            return _this.loadRvmEnvironment(env, function(err, env) {
              if (err) {
                return callback(err);
              } else {
                return callback(null, env);
              }
            });
          }
        });
      });
    };

    PooledApplication.prototype.initialize = function() {
      var _this = this;
      if (this.state) {
        if (this.state === "terminating") {
          this.quit(function() {
            return _this.initialize();
          });
        }
        return;
      }
      this.state = "initializing";
      return this.loadEnvironment(function(err, env) {
        var readyCallback, _i, _len, _ref2, _ref3, _ref4;
        if (err) {
          _this.state = null;
          _this.logger.error(err.message);
          _this.logger.error("stdout: " + err.stdout);
          _this.logger.error("stderr: " + err.stderr);
        } else {
          _this.state = "ready";
          _this.pool = _this.createPool({
            env: env,
            size: (_ref2 = env != null ? env.POW_WORKERS : void 0) != null ? _ref2 : _this.configuration.workers,
            idle: ((_ref3 = env != null ? env.POW_TIMEOUT : void 0) != null ? _ref3 : _this.configuration.timeout) * 1000
          });
        }
        _ref4 = _this.readyCallbacks;
        for (_i = 0, _len = _ref4.length; _i < _len; _i++) {
          readyCallback = _ref4[_i];
          readyCallback(err);
        }
        return _this.readyCallbacks = [];
      });
    };

    PooledApplication.prototype.terminate = function() {
      var _this = this;
      if (this.state === "initializing") {
        return this.ready(function() {
          return _this.terminate();
        });
      } else if (this.state === "ready") {
        this.state = "terminating";
        return this.pool.quit(function() {
          var quitCallback, _i, _len, _ref2;
          _this.state = null;
          _this.mtime = null;
          _this.pool = null;
          _ref2 = _this.quitCallbacks;
          for (_i = 0, _len = _ref2.length; _i < _len; _i++) {
            quitCallback = _ref2[_i];
            quitCallback();
          }
          return _this.quitCallbacks = [];
        });
      }
    };

    PooledApplication.prototype.handle = function(req, res, next, callback) {
      var resume,
        _this = this;
      resume = pause(req);
      return this.ready(function(err) {
        if (err) {
          return next(err);
        }
        return _this.setPoolRunOnceFlag(function() {
          return _this.restartIfNecessary(function() {
            return _this.sendToPool(req, res, next, resume, callback);
          });
        });
      });
    };

    PooledApplication.prototype.restart = function(callback) {
      var _this = this;
      return this.quit(function() {
        return _this.ready(callback);
      });
    };

    PooledApplication.prototype.restartIfNecessary = function(callback) {
      var _this = this;
      return this.queryRestartFile(function(mtimeChanged) {
        if (mtimeChanged) {
          return _this.restart(callback);
        } else {
          return callback();
        }
      });
    };

    PooledApplication.prototype.writeRvmBoilerplate = function() {
      var boilerplate, powrc;
      powrc = join(this.root, ".powrc");
      boilerplate = this.constructor.rvmBoilerplate;
      return fs.readFile(powrc, "utf8", function(err, contents) {
        if (contents == null) {
          contents = "";
        }
        if (contents.indexOf(boilerplate) === -1) {
          return fs.writeFile(powrc, "" + boilerplate + "\n" + contents);
        }
      });
    };

    PooledApplication.rvmBoilerplate = "if [ -f \"$rvm_path/scripts/rvm\" ] && [ -f \".rvmrc\" ]; then\n  source \"$rvm_path/scripts/rvm\"\n  source \".rvmrc\"\nfi";

    return PooledApplication;

  })();

}).call(this);