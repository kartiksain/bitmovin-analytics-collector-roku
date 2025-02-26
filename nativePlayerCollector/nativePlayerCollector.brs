sub init()
  m.tag = "[nativePlayerCollector] "
  m.collectorCore = m.top.FindNode("collectorCore")
  m.videoStartTimeoutTimer = m.top.FindNode("videoStartTimeoutTimer")
  m.videoStartFailedEvents = getVideoStartFailedEvents()
  m.playerStateTimer = CreateObject("roTimespan")
  m.deviceInfo = CreateObject("roDeviceInfo")
end sub

sub initializeAnalytics(config = invalid)
  m.collectorCore.callFunc("initializeAnalytics", config)
end sub

sub initializePlayer(player)
  unobserveFields()
  m.player = player

  setUpHelperVariables()
  setUpObservers()

  m.previousState = ""
  m.currentState = player.state

  eventData = {
    player: "Roku",
    playerTech: "native",
    version: getPlayerVersion(),

    playerStartupTime: 1
  }
  sendAnalyticsRequestAndClearValues(eventData, 0, "setup")
end sub

sub destroy(param = invalid)
  unobserveFields()

  if m.collectorCore <> invalid
    m.collectorCore.callFunc("internalDestroy", invalid)
  end if
end sub

sub setUpObservers()
  m.player.observeFieldScoped("content", "onSourceChanged")
  m.player.observeFieldScoped("state", "onPlayerStateChanged")
  m.player.observeFieldScoped("seek", "onSeek")

  m.player.observeFieldScoped("control", "onControlChanged")

  m.collectorCore.observeFieldScoped("fireHeartbeat", "onHeartbeat")
end sub

sub unobserveFields()
  if m.player <> invalid
    m.player.unobserveFieldScoped("content")
    m.player.unobserveFieldScoped("contentIndex")
    m.player.unobserveFieldScoped("state")
    m.player.unobserveFieldScoped("seek")

    m.player.unobserveFieldScoped("control")
  end if

  if m.collectorCore <> invalid
    m.collectorCore.unobserveFieldScoped("fireHeartbeat")
  end if
end sub

sub setUpHelperVariables()
  m.seekStartPosition = invalid
  m.alreadySeeking = false

  m.newMetadata = invalid

  m.playerStates = getPlayerStates()
  m.playerControls = getPlayerControls()

  m.videoStartupTime = -1
  m.manualSourceChangeInProgress = false

  m.didAttemptPlay = false
  m.didVideoPlay = false
end sub

sub onPlayerStateChanged()
  if m.manualSourceChangeInProgress = true and m.player.state <> m.playerStates.PLAYING
    return
  end if
  transitionToState(m.player.state)
  m.collectorCore.playerState = m.currentState

  setVideoTimeEnd()
  handlePreviousState(m.previousState)
  handleCurrentState()

  m.playerStateTimer.Mark()
  setVideoTimeStart()
end sub

sub handlePreviousState(previousState)
  if m.manualSourceChangeInProgress = true and m.currentState = m.playerStates.PLAYING
    onSourceLoaded()
  else if previousState = m.playerStates.PLAYING and m.currentState <> m.playerStates.READY
    onPlayed(previousState)
  else if previousState = m.playerStates.PAUSED and m.currentState <> m.playerStates.READY
    onPaused(previousState)
  else if previousState = m.playerStates.BUFFERING and m.currentState <> m.playerStates.READY
    onBufferingEnd(previousState)
  end if
end sub

function wasSeeking()
  return m.seekTimer <> invalid
end function

sub handleCurrentState()
  if m.currentState = m.playerStates.PLAYING
    onVideoStart()
    if wasSeeking() then onSeeked()
  else if m.currentState = m.playerStates.PAUSED
    onPause()
  else if m.currentState = m.playerStates.ERROR
    onError()
  else if m.currentState = m.playerStates.BUFFERING
    onBuffering()
  else if m.currentState = m.playerStates.FINISHED
    onFinished()
  end if
end sub

sub handleIntermediateState(intermediateState)
  transitionToState(intermediateState)
  setVideoTimeEnd()

  handlePreviousState(intermediateState)

  m.playerStateTimer.Mark()
  setVideoTimeStart()
  transitionToState(m.previousState)
end sub

sub onPlay()
  startVideoStartUpTimer()

  if m.didAttemptPlay = false and m.didVideoPlay = false then startVideoStartTimeoutTimer()

  m.didAttemptPlay = true
end sub

sub onPlayed(state)
  played = m.playerStateTimer.TotalMilliseconds()
  eventData = {
    played: played
  }

  sendAnalyticsRequestAndClearValues(eventData, played, state)
end sub

sub onPause()
  ' The video node does not have a seeking state, because of that we have to assume that on pause is the beginning of a seek operation until proven otherwise
  m.alreadySeeking = true
  m.seekStartPosition = getCurrentPlayerTimeInMs()
  m.seekTimer = createObject("roTimeSpan")
end sub

sub onPaused(state)
  ' If we did not change from the pause state to playing that means a seek is happening
  if m.currentState <> m.playerStates.PLAYING and m.currentState <> m.playerStates.SOURCE_CHANGING then return

  paused = m.playerStateTimer.TotalMilliseconds()
  eventData = {
    paused: paused
  }

  sendAnalyticsRequestAndClearValues(eventData, paused, state)
  resetSeekHelperVariables()
end sub

sub resetSeekHelperVariables()
  m.alreadySeeking = false
  m.seekStartPosition = invalid
  m.seekTimer = invalid
end sub

sub onBuffering()
  ' If we did not change from playing to buffering that means the buffering was caused by a seek and thus we do not report it
  if m.previousState <> m.playerStates.PLAYING then return
  m.bufferTimer = CreateObject("roTimespan")
end sub

sub resetBufferingTimer()
  m.bufferTimer = invalid
end sub

sub onBufferingEnd(state)
  if m.bufferTimer = invalid then return

  buffered = m.bufferTimer.TotalMilliseconds()
  eventData = {
    buffered: buffered
  }

  setVideoTimeStart() ' Buffering blocks the video
  sendAnalyticsRequestAndClearValues(eventData, buffered, state)
  resetBufferingTimer()
end sub

sub onFinished()
  resetBufferingTimer()
  resetSeekHelperVariables()
end sub

sub onHeartbeat()
  setVideoTimeEnd()

  duration = getDuration(m.playerStateTimer)
  m.playerStateTimer.Mark()

  eventData = {
    played: duration
  }

  sendAnalyticsRequestAndClearValues(eventData, duration, m.player.state)
  setVideoTimeStart()
end sub

sub transitionToState(nextState)
  m.previousState = m.currentState
  m.currentState = nextState
end sub

sub decorateSampleWithPlaybackData(sampleData)
  if sampleData = invalid then return

  sampleData.Append(getVideoWindowSize(m.player))
  sampleData.Append({size: getSizeType(sampleData.videoWindowHeight, sampleData.videoWindowWidth)})

  ' Set audio language
  for each audioTrack in m.player.availableAudioTracks
    if audioTrack.Track = m.player.currentAudioTrack
      sampleData.Append({audioLanguage: audioTrack.Language})
    end if
  end for

  ' Set subtitle language
  for each subtitleTrack in m.player.availableSubtitleTracks
    if subtitleTrack.TrackName = m.player.currentSubtitleTrack
      sampleData.Append({subtitleLanguage: subtitleTrack.Language})
    end if
  end for

  ' Set subtitle enabled
  subtitleEnabled = false
  if m.deviceInfo.GetCaptionsMode() = "On" then
    subtitleEnabled = True
  end if
  sampleData.Append({subtitleEnabled: subtitleEnabled})

  ' Set video duration
  videoDuration = m.player.duration * 1000
  sampleData.Append({videoDuration: videoDuration})
end sub

sub createTempMetadataSampleAndSendAnalyticsRequest(eventData, duration, state = m.previousState)
  sampleData = eventData
  sampleData.Append({
    state: state,
    duration: duration,
    time: getCurrentTimeInMilliseconds()
  })
  decorateSampleWithPlaybackData(sampleData)

  m.collectorCore.callFunc("createTempMetadataSampleAndSendAnalyticsRequest", sampleData)
end sub

function updateSample(sampleData)
  if sampleData = invalid return false

  return m.collectorCore.callFunc("updateSample", sampleData)
end function

sub onSeek()
  if m.alreadySeeking = true then return

  m.alreadySeeking = true
  m.seekStartPosition = getCurrentPlayerTimeInMs()
  m.seekTimer = createObject("roTimeSpan")
end sub

sub onSeeked()
  duration = m.seekTimer.TotalMilliseconds()
  eventData = {
    videoTimeStart: m.seekStartPosition,
    seeked: duration
  }

  sendAnalyticsRequestAndClearValues(eventData, duration, m.playerStates.SEEKING)
  setVideoTimeStart() ' Finished seeking does not trigger a state change, need to manually set videoTimeStart
  resetSeekHelperVariables()
end sub

sub onControlChanged()
  if m.player.control = m.playerControls.PLAY then onPlay()
end sub

sub startVideoStartUpTimer()
  m.videoStartupTimer = CreateObject("roTimeSpan")
end sub

sub stopVideoStartUpTimer()
  if m.videoStartupTimer = invalid or m.videoStartupTime >= 0 then return

  m.videoStartUpTime = m.videoStartupTimer.TotalMilliseconds()
  eventData = {
    videoStartupTime: m.videoStartupTime,
    startupTime: m.videoStartUpTime,
    videoTimeStart: 0,
    videoTimeEnd: 0
  }

  sendAnalyticsRequestAndClearValues(eventData, m.videoStartUpTime, "startup")
  m.videoStartupTimer = invalid
  m.videoStartUpTime = -1
end sub

sub onVideoStart()
  stopVideoStartUpTimer()

  if m.didVideoPlay = false
    m.didVideoPlay = true
    clearVideoStartTimeoutTimer()
  end if
end sub

function mapContent(content)
  if content.STREAMFORMAT = "dash"
    return { streamFormat: "dash", mpdUrl: content.URL }
  else if content.STREAMFORMAT = "hls"
    return { streamFormat: "hls", m3u8Url: content.URL }
  else if content.STREAMFORMAT = "smooth"
    return { streamFormat: "smooth"}
  else if content.STREAMFORMAT = "mp4"
    return { streamFormat: "mp4", progUrl: content.URL }
  else
    return {}
  end if
end function

sub checkForSourceSpecificMetadata(sourceConfig)
  newVideoMetadata = mapContent(sourceConfig)
  updateSample(newVideoMetadata)
end sub

sub onSourceLoaded()
  m.manualSourceChangeInProgress = false
end sub

sub onSourceChanged()
  if m.player.state = m.playerStates.PLAYING
    startVideoStartUpTimer()
  end if

  ' Do not change impression id when it is an initial source change
  if m.currentState <> m.playerStates.NONE
    handleManualSourceChange()
  else
    checkForSourceSpecificMetadata(m.player.content)
  end if
end sub

sub handleManualSourceChange()
  if m.player.content.getChildCount() > 0
    m.player.unobserveFieldScoped("contentIndex")
    m.player.observeFieldScoped("contentIndex", "onSourceChanged")
  end if

  startVideoStartUpTimer()
  transitionToState(m.playerStates.SOURCE_CHANGING)
  handlePreviousState(m.previousState)
  transitionToState(m.previousState)
  m.playerStateTimer.Mark()
  m.manualSourceChangeInProgress = true

  checkForSourceSpecificMetadata(m.player.content)
  m.collectorCore.callFunc("setupSample")
end sub

sub setNewMetadata(metadata = invalid)
  if metadata = invalid then return

  m.newMetadata = metadata
end sub

sub checkForNewMetadata()
  if m.newMetadata = invalid then return

  updateSample(m.newMetadata)
  m.newMetadata = invalid
end sub

sub onError()
  setVideoTimeEnd()

  errorSample = {
    errorCode: m.player.errorCode,
    errorMessage: m.player.errorMsg
  }

  duration = getDuration(m.playerStateTimer)
  resetSeekHelperVariables()
  resetBufferingTimer()

  if m.didAttemptPlay = true and m.didVideoPlay = false
    videoStartFailed(m.videoStartFailedEvents.PlayerError, duration, m.player.state, errorSample)
  else
    ' Previous sample is already sent, no duration needed
    sendAnalyticsRequestAndClearValues(errorSample, 0, m.player.state)
  end if

  ' Stop collecting data
  unobserveFields()
end sub

sub startVideoStartTimeoutTimer()
  m.videoStartTimeoutTimer.observeFieldScoped("fire", "onVideoStartTimeout")
  m.videoStartTimeoutTimer.control = "start"
end sub

sub clearVideoStartTimeoutTimer()
  m.videoStartTimeoutTimer.unobserveFieldScoped("fire")
  m.videoStartTimeoutTimer.control = "stop"
end sub

sub onVideoStartTimeout()
  durationMilliseconds = m.videoStartTimeoutTimer.duration * 1000
  videoStartFailed(m.videoStartFailedEvents.Timeout, durationMilliseconds, m.player.state)
end sub

'Trigger videoStartFailed sample
'@param {String} reason - Reason why videostart failed
'@param {number} duration - Duration of the state in milliseconds
'@param {String} state - State of the player in which the failure happened
'@param {Object} additionalEventData - Additional event data that is added to the sample
sub videoStartFailed(reason, duration, state, additionalEventData = invalid)
  if reason = invalid return

  clearVideoStartTimeoutTimer()

  eventData = {}
  if additionalEventData <> invalid then eventData.Append(additionalEventData)

  eventData.Append({
    videoStartFailed: true,
    videoStartFailedReason: reason
  })
  sendAnalyticsRequestAndClearValues(eventData, duration, state)
end sub

function setCustomData(customData)
  if customData = invalid then return invalid
  finishRunningSample()

  return updateSample(customData)
end function

sub finishRunningSample()
  duration = getDuration(m.playerStateTimer)
  m.playerStateTimer.Mark()

  sendAnalyticsRequestAndClearValues({}, duration)
end sub

sub setCustomDataOnce(customData)
  if customData = invalid then return
  finishRunningSample()
  sendOnceCustomData = createUpdatedSampleData(m.previousState, m.playerStateTimer, m.playerStates, customData)

  createTempMetadataSampleAndSendAnalyticsRequest(sendOnceCustomData)
end sub

sub setAnalyticsConfig(config)
  if config = invalid then return

  m.collectorCore.callFunc("updateAnalyticsConfig", config)
end sub

sub sendAnalyticsRequestAndClearValues(eventData, duration, state = m.previousState)
  sampleData = eventData
  sampleData.Append({
    state: state,
    duration: duration,
    time: getCurrentTimeInMilliseconds()
  })
  decorateSampleWithPlaybackData(sampleData)

  updateSample(sampleData)
  m.collectorCore.callFunc("sendAnalyticsRequestAndClearValues")
end sub

sub setVideoTimeStart()
  m.collectorCore.callFunc("setVideoTimeStart", getCurrentPlayerTimeInMs())
end sub

sub setVideoTimeEnd()
  m.collectorCore.callFunc("setVideoTimeEnd", getCurrentPlayerTimeInMs())
end sub

function getCurrentPlayerTimeInMs()
  time% = m.player.position * 1000
  return Cint(time%)
end function

function getPlayerVersion()
  version = m.deviceInfo.GetOSVersion()
  return "roku-" + version.major + "." + version.minor + "." + version.build
end function
