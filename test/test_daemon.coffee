net = require "net"
path = require "path"
{testCase} = require "nodeunit"
{Configuration, Daemon} = require ".."
{prepareFixtures, fixturePath, touch} = require "./lib/test_helper"

module.exports = testCase
  setUp: (proceed) ->
    prepareFixtures proceed

  "start and stop": (test) ->
    test.expect 2

    configuration = new Configuration POW_HOST_ROOT: fixturePath("tmp"), POW_HTTP_PORT: 0, POW_DNS_PORT: 0
    daemon = new Daemon configuration

    daemon.on "start", ->
      test.ok daemon.started
      daemon.on "stop", ->
        test.ok !daemon.started
        test.done()

      daemon.stop()

    daemon.start()

  "start rolls back when it can't boot a server": (test) ->
    test.expect 2

    server = net.createServer()
    server.listen 0, ->
      port = server.address().port
      configuration = new Configuration POW_HOST_ROOT: fixturePath("tmp"), POW_HTTP_PORT: port
      daemon = new Daemon configuration

      daemon.once "error", (err) ->
        test.ok err
        test.ok !daemon.started
        server.on 'close', ->
          test.done()
        server.close()

      daemon.start()

  "touching restart.txt removes the file and emits a restart event": (test) ->
    test.expect 1

    restartFilename = path.join fixturePath("tmp"), "restart.txt"
    configuration = new Configuration POW_HOST_ROOT: fixturePath("tmp"), POW_HTTP_PORT: 0, POW_DNS_PORT: 0
    daemon = new Daemon configuration

    daemon.start()
    daemon.once "start", ->
      touch restartFilename, ->
        daemon.once "restart", ->
          path.exists restartFilename, (exists) ->
            test.ok !exists
            daemon.stop()
            daemon.on "stop", ->
              test.done()
