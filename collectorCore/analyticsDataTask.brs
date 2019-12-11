sub init()
  m.tag = "[analyticsDataTask] "
  m.config = getCollectorCoreConfig()
  m.deviceinfo = CreateObject("roDeviceInfo")
  m.licensingState = m.top.findNode("licensingState")
  m.isLicensingCallDone = false
  m.analyticsEventsQueue = []
  m.timer = CreateObject("roTimespan")
  m.appInfo = CreateObject("roAppInfo")
  m.top.url = m.config.serviceEndpoints.analyticsLicense
  m.licensingResponse = {}
  m.analyticsDataTaskPort = CreateObject("roMessagePort")
  m.top.observeFieldScoped("checkLicenseKey", m.analyticsDataTaskPort)
  m.top.observeFieldScoped("sendData", m.analyticsDataTaskPort)
  m.top.observeFieldScoped("eventData", m.analyticsDataTaskPort)
  m.top.functionName = "execute"
  m.top.control = "RUN"
end sub

sub execute()
  m.timer.Mark()

  while true
    msg = wait(500, m.analyticsDataTaskPort)

    if type(msg) = "roSGNodeEvent"
      field = msg.GetField()
      data = msg.GetData()
      if field = "sendData"
        if data = true
          if m.isLicensingCallDone = true
            sendAnalyticsEventsFromQueue()
          end if
        end if
      else if field = "eventData"
        event = data
        pushToAnalyticsEventsQueue(event)
      else if field = "checkLicenseKey"
        if data = true
          checkLicenseKey(m.top.licensingData, m.top.url)
        end if
      end if
    end if

    if m.licensingState <> "granted"
      clearAnalyticsEventsQueue()()
      return
    end if

    if m.top.playerState = "playing" and m.timer.totalMilliseconds() > 59*1000
      parent = m.top.getParent()
      if parent.fireHeartbeat <> invalid
        parent.fireHeartbeat = true
        m.timer.Mark()
      end if
    end if

  end while
end sub

function checkLicenseKey(licensingData, url)
  http = CreateObject("roUrlTransfer")
  http.setCertificatesFile("common:/certs/ca-bundle.crt")
  port = CreateObject("roMessagePort")
  http.setPort(port)
  http.setUrl(url)
  http.addHeader("Origin", m.appInfo.getID())

  data = formatJson(licensingData)

  if http.asyncPostFromString(data)
    msg = wait(0, port)
    if type(msg) = "roUrlEvent"
      responseCode = msg.getResponseCode()
      if responseCode >= 200 and responseCode < 300
        m.licensingResponse = parseJson(msg.getString())
        if m.licensingResponse.status = "granted"
          m.licensingState = m.licensingResponse.status
        end if
      else
        m.licensingResponse = {}
        clearAnalyticsEventsQueue()()
      end if
      m.isLicensingCallDone = true
      http.asyncCancel()
    else if msg = invalid
      m.licensingResponse = {}
      http.asyncCancel()
    end if
  end if

  m.timer.Mark()
end function

sub sendAnalyticsData(eventData)
  url = m.config.serviceEndpoints.analyticsData
  http = CreateObject("roUrlTransfer")
  http.SetCertificatesFile("common:/certs/ca-bundle.crt")
  port = CreateObject("roMessagePort")
  http.setPort(port)
  http.setUrl(url)
  http.AddHeader("Origin", m.appInfo.getID())

  data = FormatJson(eventData)

  if http.asyncPostFromString(data)
    msg = wait(0, port)
    if type(msg) = "roUrlEvent"
      if msg.getResponseCode() >= 200 and msg.getResponseCode() < 300
        ' Event data request successful!
      else
        ' Event data request failed
      end if
      http.asyncCancel()
    else if msg = invalid
      ' Event data request failed
      http.asyncCancel()
    end if
  end if

  m.timer.mark()
end sub

sub sendAnalyticsEventsFromQueue()
  if m.analyticsEventsQueue.Count() = 0 then return
  for each event in m.analyticsEventsQueue
    sendAnalyticsData(event)
  end for
  clearAnalyticsEventsQueue()
end sub

function clearAnalyticsEventsQueue()
  if m.analyticsEventsQueue.Count() = 0 then return invalid

  return m.analyticsEventsQueue.Clear()
end function

function pushToAnalyticsEventsQueue(event)
  if event = invalid then return invalid

  return m.analyticsEventsQueue.Push(event)
end function