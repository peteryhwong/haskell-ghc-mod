{Emitter, CompositeDisposable} = require('atom')
CP = require('child_process')
{debug, mkError} = require './util'
{EOL} = require('os')
EOT = "#{EOL}\x04#{EOL}"

module.exports =
class InteractiveProcess
  constructor: (path, cmd, options, @caps) ->
    @disposables = new CompositeDisposable
    @disposables.add @emitter = new Emitter
    @interactiveAction = Promise.resolve()

    debug "Spawning new ghc-modi instance for #{options.cwd} with
          #{"options.#{k} = #{v}" for k, v of options}"
    @proc = CP.spawn(path, cmd, options)
    @proc.stdout.setEncoding 'utf-8'
    @proc.stderr.setEncoding 'utf-8'
    lastLine = ""
    @proc.stderr.on 'data', (data) ->
      [first, rest..., last] = data.split(EOL)
      if last?
        console.warn "ghc-modi said: #{lastLine + first}"
        lastLine = last
      else
        lastLine = lastLine + first
      rest.forEach (line) ->
        console.warn "ghc-modi said: #{line}"
    @resetTimer()
    @proc.on 'exit', (code) =>
      clearTimeout @timer
      debug "ghc-modi for #{options.cwd} ended with #{code}"
      @emitter.emit 'did-exit', code
      @disposables.dispose()

  onExit: (action) ->
    @emitter.on 'did-exit', action

  resetTimer: ->
    if @timer?
      clearTimeout @timer
    @timer = setTimeout (=> @kill()), 60 * 60 * 1000

  kill: ->
    if @timer?
      clearTimeout @timer
    @proc.stdin?.end?()
    @proc.kill?()

  do: (action) ->
    @resetTimer()
    interact = (command, args, data) =>
      resultP =
        new Promise (resolve, reject) =>
          savedLines = []
          exitCallback = null
          parseData = null
          timer = null
          cleanup = =>
            @proc.stdout.removeListener 'data', parseData
            @proc.removeListener 'exit', exitCallback
            clearTimeout timer
          parseData = (data) ->
            debug "Got response from ghc-modi:#{EOL}#{data}"
            lines = data.split(EOL)
            savedLines = savedLines.concat lines
            result = savedLines[savedLines.length - 2]
            if result is 'OK'
              cleanup()
              lines = savedLines.slice(0, -2)
              resolve lines.map (line) ->
                line.replace /\0/g, EOL
          exitCallback = ->
            cleanup()
            console.error "#{savedLines}"
            reject mkError "ghc-modi crashed", "#{savedLines}"
          @proc.stdout.on 'data', parseData
          @proc.on 'exit', exitCallback
          timer = setTimeout (->
            cleanup()
            console.error "#{savedLines}"
            reject mkError "Timeout", "#{savedLines}"
            ), 60000
      debug "Running ghc-modi command #{command.split(EOL)[0]}"
      args_ =
        if @caps.quoteArgs
          args.map (x) -> "\x02#{x}\x03"
        else
          args
      @proc.stdin.write "#{command} #{args_.join(' ').replace(EOL, ' ')}#{EOL}"
      if data?
        @proc.stdin.write "#{data}#{EOT}"
      return resultP
    @interactiveAction = @interactiveAction.then ->
      action(interact)