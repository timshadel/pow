// Generated by CoffeeScript 1.3.3
(function() {
  var PooledApplication, ProcfileApplication, join, norman,
    __hasProp = {}.hasOwnProperty,
    __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
    __slice = [].slice;

  PooledApplication = require('./pooled_application');

  norman = require('norman');

  join = require("path").join;

  module.exports = ProcfileApplication = (function(_super) {

    __extends(ProcfileApplication, _super);

    function ProcfileApplication() {
      ProcfileApplication.__super__.constructor.apply(this, arguments);
      this.procfile = join(this.root, "Procfile");
      this.server = norman.createServer(this.procfile);
      this.server.runOnce = false;
    }

    ProcfileApplication.prototype.createPool = function(options) {
      var _this = this;
      this.server.spawn(options, function() {
        var _ref, _ref1, _ref2;
        return _this.apps = (_ref = _this.server) != null ? (_ref1 = _ref.formation) != null ? (_ref2 = _ref1.pools) != null ? _ref2['web'] : void 0 : void 0 : void 0;
      });
      return this.server;
    };

    ProcfileApplication.prototype.sendToPool = function(req, res, next, resume, callback) {
      var original_end, port, _ref, _ref1;
      port = (_ref = this.apps) != null ? (_ref1 = _ref[0]) != null ? _ref1.port : void 0 : void 0;
      if (port == null) {
        return next();
      }
      try {
        req.pow.url = "http://localhost:" + port;
        console.log("Procfile app set req.pow.url = " + req.pow.url);
        if (this.server.runOnce) {
          original_end = res.end;
          res.end = function() {
            var args,
              _this = this;
            args = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
            this.server.quit(function() {
              return _this.server.spawn;
            });
            return original_end.apply(null, args);
          };
        }
        return next();
      } finally {
        resume();
        if (typeof callback === "function") {
          callback();
        }
      }
    };

    return ProcfileApplication;

  })(PooledApplication);

}).call(this);