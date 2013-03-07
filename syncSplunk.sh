#! /usr/bin/env groovy

import groovy.json.JsonSlurper
import net.sf.json.JSONArray
import net.sf.json.JSONObject
import org.apache.commons.logging.LogFactory
import org.apache.http.HttpEntity
import org.apache.http.HttpHost
import org.apache.http.HttpResponse
import org.apache.http.NameValuePair
import org.apache.http.client.HttpClient
import org.apache.http.client.entity.UrlEncodedFormEntity
import org.apache.http.client.methods.HttpDelete
import org.apache.http.client.methods.HttpGet
import org.apache.http.client.methods.HttpPost
import org.apache.http.client.methods.HttpPut
import org.apache.http.client.utils.URIUtils
import org.apache.http.client.utils.URLEncodedUtils
import org.apache.http.conn.scheme.Scheme
import org.apache.http.conn.ssl.AllowAllHostnameVerifier
import org.apache.http.conn.ssl.SSLSocketFactory
import org.apache.http.conn.ssl.TrustStrategy
import org.apache.http.entity.ContentType
import org.apache.http.entity.StringEntity
import org.apache.http.impl.client.DefaultHttpClient
import org.apache.http.impl.conn.PoolingClientConnectionManager
import org.apache.http.message.BasicHeader
import org.apache.http.message.BasicNameValuePair

import java.security.cert.CertificateException
import java.security.cert.X509Certificate

@Grapes([
    @Grab(group = 'org.codehaus.groovy.modules.http-builder', module = 'http-builder', version = '0.6')
])

def startTime = System.currentTimeMillis()
System.out.println(" [Initializing...] ")

// Define constants
def String defaultHost = "https://localhost:8089"
def boardBasePushURL = "https://push.geckoboard.com/v1/send"
// Account api key
def apiKey = "8b27afebd6aa68661e4ad88488239c76"

// Widget keys (type, description)
// Number. Displays total number of error logs.
def String errorLogsCountWidgetKey = "28094-2d5eb053-14fc-4a16-8fc5-d08a6d67d941"
// Text. Displays last update time.
def String updateTimeWidgetKey = "28094-6cb776a0-a0fb-46c4-9807-78ab0b0501a9"
// Text. Displays search string.
def String searchStringWidgetKey = "28094-5f7cf6b7-4543-4ef2-ac2b-809cc8c2621c"
// Text. Displays value of search lower bound of search time.
def String searchTimeParamWidgetKey = "28094-08bf0bf5-aa3a-4374-9d84-a5b170cf4833"

// Parse command line options
def CliBuilder cli = new CliBuilder(usage: 'syncSplunk.sh [options] ', header: 'Options:')
cli.with {
    u(longOpt: 'username', args: 1, required: true, argName: 'username', "Username used to access Splunk server")
    p(longOpt: 'password', args: 1, required: true, argName: 'password', "Password for specified username")
    h(longOpt: 'host', args: 1, required: false, argName: 'host', "Base URL of Splunk server. Default is: \"${defaultHost}\"")
    e(longOpt: 'error-id', args: 1, required: false, argName: 'error-id', "Identifier to search Error logs using Splunk. Default is 'ERROR'. Use with -r option to use it as regex expression.")
    r(longOpt: 'regex', args: 0, required: false, "Allow using identifier from -e option or its default value as regular expression pattern")
    s(longOpt: 'sourcetype', args: 1, required: false, argName: 'sourcetype', "Value for 'sourcetype' parameter of Splunk search filtering. All source types used for search by default: '*'")
    S(longOpt: 'source', args: 1, required: false, argName: 'source', "Value for 'source' parameter of Splunk search filtering. All sources used for search by default: '*'")
    f(longOpt: 'fields', args: 1, required: false, argName: 'fields', "Comma-separated list of fields used to perform Splunk search. Field filter is not specified by default")
    t(longOpt: 'time', args: 1, required: false, argName: 'time', "Value of Splunk search start time parameter (earliest_time). Default is '-4h' that means 'for last 4 hours'. See Splunk docs for details")
}
def options = cli.parse(args)
if (!options) {
    return
}
def URI splunkBaseURL = new URI(options.getInner().getOptionValue('h', defaultHost))
def String username = options.getInner().getOptionValue('u')
def String password = options.getInner().getOptionValue('p')
def String errorLogID = options.getInner().getOptionValue('e', "ERROR")
def Boolean regex = options.r
def String sourcetype = options.getInner().getOptionValue('s', '*')
def String source = options.getInner().getOptionValue('S', '*')
def String fields = options.getInner().getOptionValue('f', "")
def String searchStartTime = options.getInner().getOptionValue('t', "-4h")

def String fieldFilter = (fields.isEmpty()) ? "" : "fields + ${fields}"
def String searchString = "sourcetype=\"${sourcetype}\" source=\"${source}\" ${fieldFilter} | ${(regex) ? "regex" : "search"} ${errorLogID} | fields + linecount | stats | fields + count(linecount) | rename count(linecount) AS count"

// Create and initialize clients

// Splunk client
def splunkClient = new SplunkRESTClient(splunkBaseURL.toString())

// Geckoboard client
def pushClient = new GeckoboardPushClient(apiKey, boardBasePushURL)

// Syncing
System.out.println(" [Start polling data from Splunk] ")

try {
    // Authenticate user on Splunk server
    splunkClient.authenticate(username, password)

    // Set timestamp
    def Date timestamp = new Date()

    // Create search job
    def String searchID = splunkClient.createSearchJob(searchString, searchStartTime)

    // Check the status
    def String status = splunkClient.getSearchJobStatus(searchID)
    def Integer attempts = 5
    def Long time = System.currentTimeMillis()
    while (!status.equals(SearchJobStatus.DONE.name()) && !status.equals(SearchJobStatus.FAILED.name()) && attempts > 0) {
        Thread.sleep(2000)
        System.out.println("Obtaining status of search job with id=${searchID}...")
        status = splunkClient.getSearchJobStatus(searchID)
        attempts -= 1
    }

    if (!status.equals(SearchJobStatus.DONE.name())) {
        throw new RuntimeException("Search job failed or did not completed in appropriate time. Job status: ${status}. Execution time: ${System.currentTimeMillis() - time} ms")
    }

    // Obtain search job results
    System.out.println("Obtaining results of search job with id=${searchID}...")
    def List<JSONObject> results = splunkClient.getSearchJobResults(searchID)

    def count = 0
    if (!results.isEmpty()) {
        count = results.head().optLong("count", 0L)
    }

    System.out.print(" [Push Number data: error logs] ")
    pushClient.pushData(errorLogsCountWidgetKey, WidgetType.NUMBER,
            [new NumberItem(count, "logs")]
    )

    // Create time parameter description
    def String timeParamText
    def tSearchStartTime = searchStartTime.trim()
    if (tSearchStartTime.startsWith("-")) {
        def matcher = (tSearchStartTime.substring(1) =~ "(\\d+)(\\w+)")
        if (matcher.matches()) {
            def String timeUnit
            switch (matcher[0][2]) {
                case ["s", "sec", "secs", "second", "seconds"]:
                    timeUnit = "second(s)"
                    break
                case ["m", "min", "minute", "minutes"]:
                    timeUnit = "minute(s)"
                    break
                case ["h", "hr", "hrs", "hour", "hours"]:
                    timeUnit = "hour(s)"
                    break
                case ["d", "day", "days"]:
                    timeUnit = "day(s)"
                    break
                case ["w", "week", "weeks"]:
                    timeUnit = "week(s)"
                    break
                case ["mon", "month", "months"]:
                    timeUnit = "month(s)"
                    break
                case ["q", "qtr", "qtrs", "quarter", "quarters"]:
                    timeUnit = "quarters"
                    break
                case ["y", "yr", "yrs", "year", "years"]:
                    timeUnit = "years"
                    break
                default:
                    timeUnit = matcher[0][2].toString()
            }
            timeParamText = "data for last ${matcher[0][1]} ${timeUnit}."
        } else {
            timeParamText = "Unrecognized parameter value"
        }
    } else {
        try {
            def Long value = Long.parseLong(tSearchStartTime)
            timeParamText = "${value} millseconds from Epoch"
        } catch (NumberFormatException nfe) {
            timeParamText = "Unrecognized parameter value"
        }
    }

    System.out.print(" [Push Text data: search time parameter] ")
    pushClient.pushData(searchTimeParamWidgetKey, WidgetType.TEXT,
            [new TextItem("RAW parameter value: '${searchStartTime}'. Description: ${timeParamText}", TextWidgetDisplayType.INFO)]
    )

    System.out.print(" [Push Text data: complete Splunk search request] ")
    pushClient.pushData(searchStringWidgetKey, WidgetType.TEXT,
            [new TextItem(searchString.replaceAll("\"", "''"), TextWidgetDisplayType.INFO)]
    )

    System.out.print(" [Push update time data] ")
    pushClient.pushData(updateTimeWidgetKey, WidgetType.TEXT,
            [new TextItem(timestamp.toGMTString(), TextWidgetDisplayType.INFO)]
    )

} catch (Exception ex) {
    System.err.println("${ex.getMessage()}\n${ex.getCause()})")
}

System.out.println(" [Splunk metrics sync task completed. Elapsed time: ${System.currentTimeMillis() - startTime} ms] ")
return

//-----------------------------------------------------------------------------
// Classes
//-----------------------------------------------------------------------------

/**
 * Data item for Number & RAG widgets
 */
class NumberItem {
    def Long value
    def String text

    NumberItem(Long value, String text) {
        this.value = value
        this.text = text
    }
}

/**
 * Data item for PieChart widget
 */
class PieItem {
    def Long value
    def String label
    def String colour

    PieItem(Long value, String label, String colour) {
        this.label = label
        this.value = value
        this.colour = colour
    }
}

/**
 * Data item for Text widget
 */
class TextItem {
    def String text
    def TextWidgetDisplayType type

    TextItem(String text, TextWidgetDisplayType type) {
        this.text = text
        this.type = type
    }
}

/**
 * Allowed display types for Text widget message
 */
enum TextWidgetDisplayType {
    NONE(0),
    ALERT(1),
    INFO(2)

    private def Integer type

    TextWidgetDisplayType(Integer type) {
        this.type = type
    }

    def Integer getTypeConstant() {
        type
    }
}

/**
 * Allowed widget types.
 */
enum WidgetType {
    NUMBER("Number"),
    TEXT("Text"),
    RAG_NUMBERS("RAG_Numbers"),
    RAG_COLUMNS("RAG_Columns"),
    PIE_CHART("Pie_Chart")

    private def String name

    WidgetType(String name) {
        this.name = name
    }

    def getName() {
        name
    }
}

/**
 * Geckoboard Push API client
 */
class GeckoboardPushClient {

    /**
     * Geckoboard API key
     */
    private def String apiKey

    /**
     * Base URL of Geckoboard push API server
     */
    private def String pushAPIBaseURL

    /**
     * HTTP client
     */
    private def HttpClient pushClient

    /**
     * JSON slurper
     */
    private def jsonSlurper

    GeckoboardPushClient(String apiKey, String pushAPIBaseURL) {
        this.apiKey = apiKey
        this.pushAPIBaseURL = pushAPIBaseURL
        this.jsonSlurper = new JsonSlurper()

        def cm = new PoolingClientConnectionManager()
        cm.setMaxTotal(100)
        cm.setDefaultMaxPerRoute(20)
        this.pushClient = new DefaultHttpClient(cm)
    }

    def String getApiKey() {
        apiKey
    }

    def setApiKey(String apiKey) {
        this.apiKey = apiKey
    }

    def String getPushAPIBaseURL() {
        pushAPIBaseURL
    }

    def setPushAPIBaseURL(String pushAPIBaseURL) {
        this.pushAPIBaseURL = pushAPIBaseURL
    }

    /**
     * Posts data to widget.
     *
     * @param widgetKey widget key
     * @param json data json
     * @return true if data pushed successfully; false otherwise
     */
    def boolean pushData(String widgetKey, String json) {
        pushClient.connectionManager.closeExpiredConnections()
        def HttpPost pushRequest = new HttpPost("${pushAPIBaseURL}/${widgetKey}")
        pushRequest.setEntity(new StringEntity(json, ContentType.APPLICATION_JSON))
        try {
            def response = pushClient.execute(pushRequest)
            def result
            switch (response.getStatusLine().getStatusCode()) {
                case 200:
                    System.out.println("[Data push operation for widget with key=${widgetKey} completed: ${response.getStatusLine()}]")
                    result = true
                    break
                case 400:
                    def error = jsonSlurper.parseText(response.getEntity().getContent().getText()) as JSONObject
                    System.err.println("[Data push operation for widget with key=${widgetKey} failed: ${response.getStatusLine()}; ${error.opt("error")}]")
                    result = false
                    break
                default:
                    def responseAvailable = response.getEntity().getContent().available()
                    def error = (responseAvailable > 0) ?
                        jsonSlurper.parseText(response.getEntity().getContent().getText()) as JSONObject :
                        null
                    System.err.println("[Data push operation for widget with key=${widgetKey} failed: ${response.getStatusLine()}; ${error.opt("error")}]")
                    result = false
            }

            result
        } catch (Exception ex) {
            System.err.println("[Data push operation for widget with key=${widgetKey} failed: ${ex.getMessage()}]")

            false
        }
    }

    /**
     * Creates valid request payload and posts data to widget.
     *
     * @param widgetKey widget key
     * @param widgetType widget type
     * @param data data to post in correct format
     * @return true if data pushed successfully; false otherwise
     */
    def boolean pushData(String widgetKey, WidgetType widgetType, Collection data) {
        def String json
        switch (widgetType) {
            case WidgetType.NUMBER:
                json = buildNumberJSON(data)
                break
            case WidgetType.TEXT:
                json = buildTextJSON(data)
                break
            case [WidgetType.RAG_COLUMNS, WidgetType.RAG_NUMBERS]:
                json = buildRAGJSON(data)
                break
            case WidgetType.PIE_CHART:
                json = buildPieChartJSON(data)
                break
            default:
                System.err.print("Unknown widget type: ${widgetType.name}. \n")
                json = ""
        }

        pushData(widgetKey, json)
    }

    /**
     * Builds correct JSON data for Text widget. Must contain from 1 to 10 messages.
     *
     * @param items Text widget items collection
     * @return text widget json data
     */
    def String buildTextJSON(Collection<TextItem> items) {
        if ((1..10).contains(items.size())) {
            def String json = """{ "item" : ${
                items.collect { TextItem item ->
                    """{ "text" : "${item.text}", "type" : ${item.type.getTypeConstant()} }"""
                }
            }}"""
            buildBaseJSON(json)
        } else {
            throw new IllegalArgumentException("Illegal item collection size: ${items.size()}. Must have between 1 and 10 values (incl.)")
        }
    }

    /**
     * Builds correct JSON data for Number widget. Must contain from 1 to 2 elements.
     *
     * @param items data collection
     * @return json data for Number widget
     */
    def String buildNumberJSON(Collection<NumberItem> items) {
        if ((1..2).contains(items.size())) {
            def String json = """{ "item" : ${
                items.collect { NumberItem item ->
                    """{ "text" : "${item.text}", "value" : ${item.value} }"""
                }
            } }"""
            buildBaseJSON(json)
        } else {
            throw new IllegalArgumentException("Illegal item collection size: ${items.size()}. Must have between 1 and 2 values (incl.)")
        }
    }

    /**
     * Builds correct JSON data for RAG widgets. Must contain from 2 to 3 elements.
     *
     * @param items data collection
     * @return json data for RAG widgets
     */
    def String buildRAGJSON(Collection<NumberItem> items) {
        def itemsSize = items.size()
        if ((2..3).contains(itemsSize)) {
            def String json
            if (itemsSize == 2) {
                json = """{ "item" : [
                    |    { "text" : "${items.toList().first().text}", "value" : ${items.toList().first().value} },
                    |    { "text" : "", "value" : null },
                    |    { "text" : "${items.toList().last().text}", "value" : ${items.toList().last().value} }
                    |  ]}""".stripMargin('|')
            } else {
                json = """{ "item" : ${
                    items.collect { NumberItem item ->
                        """{ "text" : "${item.text}", "value" : ${item.value} }"""
                    }
                }}"""
            }
            buildBaseJSON(json)
        } else {
            throw new IllegalArgumentException("Illegal item collection size: ${items.size()}. Must have between 2 and 3 values (incl.)")
        }
    }

    /**
     * Builds correct JSON data for PieChart widget. Must contain at least 1 element.
     *
     * @param items data collection
     * @return json data for PieChart widget
     */
    def String buildPieChartJSON(Collection<PieItem> items) {
        if (items.size() > 0) {
            def String json = """{ "item" : ${
                items.collect { PieItem item ->
                    """{ "value" : ${item.value}, "label" : "${item.label}", "colour" : "${item.colour}" }"""
                }
            } }"""
            buildBaseJSON(json)
        } else {
            throw new IllegalArgumentException("Illegal item collection size: ${items.size()}. Must have at least 1 element")
        }
    }

    /**
     * Wraps data-specific JSON into common JSON structure.
     *
     * @param data widget json data
     * @return complete json payload
     */
    private def String buildBaseJSON(String data) {
        """{
        |  "api_key" : "${apiKey}",
        |  "data" : ${data}
        |}""".stripMargin('|')
    }
}

/**
 * REST Client for Splunk
 */
class SplunkRESTClient {

    /**
     * Logger.
     */
    static def log = LogFactory.getLog(this)

    /**
     * HTTP client.
     */
    private def HttpClient restClient

    /**
     * Splunk base URL.
     */
    private def String hostURL

    /**
     * URL for authentication requests.
     */
    private def String authURL

    /**
     * URL for session termination requests.
     */
    private def String logOutURL

    /**
     * URL for create search job requests.
     */
    private def String searchJobURL = "/services/search/jobs"

    /**
     * Splunk session key.
     */
    private def String sessionKey = ""

    /**
     * JSON response parser.
     */
    private def JsonSlurper jsonSlurper

    public def SplunkRESTClient(String hostURL) {
        this.hostURL = hostURL
        this.authURL = "${hostURL}/services/auth/login?output_mode=json"
        this.logOutURL = "${hostURL}/services/authentication/httpauth-tokens"
        this.jsonSlurper = new JsonSlurper()

        def SSLSocketFactory ssf = new SSLSocketFactory(new TrustStrategy() {

            public boolean isTrusted(X509Certificate[] chain, String authType) throws CertificateException {
                return true;
            }

        }, new AllowAllHostnameVerifier());

        def cm = new PoolingClientConnectionManager()
        cm.setMaxTotal(100)
        cm.setDefaultMaxPerRoute(20)

        restClient = new DefaultHttpClient(cm);
        restClient.getConnectionManager().getSchemeRegistry().register(new Scheme("https", 443, ssf));
    }

    /**
     * Sends authenticated HTTP GET request to Splunk.
     *
     * @param uri uri string (without host)
     * @param params request parameters
     * @param headers request headers
     * @return HttpResponse object
     * @throws RuntimeException in case of errors during sending request
     */
    def HttpResponse get(String uri, Map<String, String> params, Map<String, String> headers) {
        def HttpHost host = URIUtils.extractHost(new URI(hostURL))
        def List<NameValuePair> queryParams = params.collect() { name, value -> new BasicNameValuePair(name, value)}
        def HttpGet getRequest = new HttpGet(URIUtils.createURI(host.schemeName, host.hostName, host.port, uri, URLEncodedUtils.format(queryParams, "UTF-8"), null))
        getRequest.setHeader("Authorization", "Splunk ${sessionKey}")
        getRequest.setHeaders(headers.collect { name, value -> new BasicHeader(name, value) }.toArray(new BasicHeader[0]))

        try {
            log.debug("Sending GET request to Splunk server: ${getRequest.URI}")
            restClient.execute(new HttpHost(hostURL), getRequest)
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during performing GET request to Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Sends authenticated HTTP POST request to Splunk.
     *
     * @param uri uri string (without host)
     * @param params request parameters
     * @param headers request headers
     * @param body request body
     * @return HttpResponse object
     * @throws RuntimeException in case of errors during sending request
     */
    def HttpResponse post(String uri, Map<String, String> params, Map<String, String> headers, HttpEntity body) {
        def HttpHost host = URIUtils.extractHost(new URI(hostURL))
        def List<NameValuePair> queryParams = params.collect() { name, value -> new BasicNameValuePair(name, value)}
        def HttpPost postRequest = new HttpPost(URIUtils.createURI(host.schemeName, host.hostName, host.port, uri, URLEncodedUtils.format(queryParams, "UTF-8"), null))
        postRequest.setEntity(body)
        postRequest.setHeader("Authorization", "Splunk ${sessionKey}")
        postRequest.setHeaders(headers.collect { name, value -> new BasicHeader(name, value) }.toArray(new BasicHeader[0]))

        try {
            log.debug("Sending POST request to Splunk server: ${postRequest.URI}")
            restClient.execute(postRequest)
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during performing POST request to Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Sends authenticated HTTP PUT request to Splunk.
     *
     * @param uri uri string (without host)
     * @param params request parameters
     * @param headers request headers
     * @param body request body
     * @return HttpResponse object
     * @throws RuntimeException in case of errors during sending request
     */
    def HttpResponse put(String uri, Map<String, String> params, Map<String, String> headers, HttpEntity body) {
        def HttpHost host = URIUtils.extractHost(new URI(hostURL))
        def List<NameValuePair> queryParams = params.collect() { name, value -> new BasicNameValuePair(name, value)}
        def HttpPut putRequest = new HttpPut(URIUtils.createURI(host.schemeName, host.hostName, host.port, uri, URLEncodedUtils.format(queryParams, "UTF-8"), null))
        putRequest.setEntity(body)
        putRequest.setHeader("Authorization", "Splunk ${sessionKey}")
        putRequest.setHeaders(headers.collect { name, value -> new BasicHeader(name, value) }.toArray(new BasicHeader[0]))

        try {
            log.debug("Sending PUT request to Splunk server: ${putRequest.URI}")
            restClient.execute(putRequest)
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during performing PUT request to Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Sends authenticated HTTP DELETE request to Splunk.
     *
     * @param uri uri string (without host)
     * @param params request parameters
     * @param headers request headers
     * @return HttpResponse object
     * @throws RuntimeException in case of errors during sending request
     */
    def HttpResponse delete(String uri, Map<String, String> params, Map<String, String> headers) {
        def HttpHost host = URIUtils.extractHost(new URI(hostURL))
        def List<NameValuePair> queryParams = params.collect() { name, value -> new BasicNameValuePair(name, value)}
        def HttpDelete deleteRequest = new HttpDelete(URIUtils.createURI(host.schemeName, host.hostName, host.port, uri, URLEncodedUtils.format(queryParams, "UTF-8"), null))
        deleteRequest.setHeader("Authorization", "Splunk ${sessionKey}")
        deleteRequest.setHeaders(headers.collect { name, value -> new BasicHeader(name, value) }.toArray(new BasicHeader[0]))

        try {
            log.debug("Sending DELETE request to Splunk server: ${deleteRequest.URI}")
            restClient.execute(deleteRequest)
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during performing DELETE request to Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Obtains a sesssion key for accessing the Splunk REST API.
     *
     * @param username Splunk account username
     * @param password password for specified username
     * @return sessionKey to be used when making calls to Splunk REST API or empty string if auth failed
     * @throws RuntimeException in case of uncaught error during authentication routine
     */
    def String authenticate(String username, String password) {
        def HttpPost authRequest = new HttpPost(authURL)
        def authString = "${username}:${password}".getBytes().encodeBase64().toString()
        authRequest.setHeader("Authorization", "Basic ${authString}")
        authRequest.setEntity(new UrlEncodedFormEntity([
                new BasicNameValuePair("username", username),
                new BasicNameValuePair("password", password)
        ]))

        try {
            log.trace("Authenticating on Splunk server. User: ${username}")
            def HttpResponse response = restClient.execute(authRequest)
            if (response.getStatusLine().getStatusCode() == 200) {
                def String key = jsonSlurper.parseText(response.getEntity().getContent().getText()).get("sessionKey")
                sessionKey = new String(key)
                log.trace("Splunk authentication for user '${username}' completed. SessionKey saved.")
            } else {
                sessionKey = new String()
                log.warn("Splunk authentication for user '${username}' failed. Status line: ${response.getStatusLine()}")
            }

            sessionKey
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during authenticating with Splunk: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Ends current session.
     *
     * @return status of logOut operation
     * @throws RuntimeException in case of uncaught error during closing current session
     */
    def boolean logOut() {
        def HttpDelete logOutRequest = new HttpDelete("${logOutURL}/${sessionKey}")
        logOutRequest.setHeader("Authorization", "Splunk ${sessionKey}")

        try {
            log.trace("Closing connection with Splunk server")
            def HttpResponse response = restClient.execute(logOutRequest)
            def responseCode = response.getStatusLine().getStatusCode()
            if (responseCode == 200) {
                log.trace("Session '${sessionKey}' closed.")
                true
            } else {
                log.warn("Couldn't close session. Status line: ${response.getStatusLine()}")
                false
            }
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during closing connection session with Splunk: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Requests Splunk to create new search job.
     *
     * @param searchQuery search query string
     * @param startTime Splunk expression for low time bound for search
     * @return search id on success; empty string otherwise
     * @throws RuntimeException in case of uncaught errors during creating splunk search job
     */
    def String createSearchJob(String searchQuery, String startTime) {
        def HttpPost createJobRequest = new HttpPost(hostURL + searchJobURL)
        createJobRequest.setHeader("Authorization", "Splunk ${sessionKey}")
        createJobRequest.setEntity(new UrlEncodedFormEntity([
                new BasicNameValuePair("output_mode", "json"),
                new BasicNameValuePair("search", "search ${searchQuery}"),
                new BasicNameValuePair("earliest_time", startTime)
        ]))

        try {
            log.debug("Creating Splunk search Job with parameters: ${createJobRequest.getEntity().getContent().getText()}")

            def HttpResponse response = restClient.execute(createJobRequest)

            if (response.getStatusLine().getStatusCode() == 201) {
                def JSONObject answer = jsonSlurper.parseText(response.getEntity().getContent().getText()) as JSONObject
                def String searchId = answer.get("sid")
                log.debug("Search job created successfully. Search ID returned: ${searchId}. Job params: ${createJobRequest.getEntity().getContent().getText()}")
                searchId
            } else {
                log.warn("Couldn't create search job with parameters: ${createJobRequest.getEntity().getContent().getText()}")
                new String("")
            }
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during creating search job using Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Retrieves status of Splunk search job.
     *
     * @param searchID Splunk search job id
     * @return status of the search job
     * @throws RuntimeException in case of uncaught errors during obtaining search job status
     */
    def String getSearchJobStatus(String searchID) {
        def HttpHost host = URIUtils.extractHost(new URI(hostURL))
        def List<NameValuePair> queryParams = new ArrayList<NameValuePair>()
        queryParams.add(new BasicNameValuePair("output_mode", "json"))
        def HttpGet getStatusRequest = new HttpGet(URIUtils.createURI(host.schemeName, host.hostName, host.port, "${searchJobURL}/${searchID}", URLEncodedUtils.format(queryParams, "UTF-8"), null))
        getStatusRequest.setHeader("Authorization", "Splunk ${sessionKey}")

        try {
            log.debug("Checking status of Splunk search job with id=${searchID}")
            def HttpResponse response = restClient.execute(getStatusRequest)
            if (response.getStatusLine().getStatusCode() == 200) {
                def JSONObject answer = jsonSlurper.parseText(response.getEntity().getContent().getText()) as JSONObject
                def JSONArray entries = answer.getJSONArray("entry")
                entries.empty ?
                    SearchJobStatus.FAILED.name() :
                    entries.head().content.dispatchState.toString()
            } else {
                SearchJobStatus.FAILED.name()
            }
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during obtaining status of search job using Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }

    /**
     * Retrieves results of the search job.
     *
     * @param searchID Splunk search job id
     * @return search job results
     * @throws RuntimeException in case of uncaught errors during obtaining search job results
     */
    def List<JSONObject> getSearchJobResults(String searchID) {
        def HttpHost host = URIUtils.extractHost(new URI(hostURL))
        def List<NameValuePair> qparams = new ArrayList<NameValuePair>();
        qparams.add(new BasicNameValuePair("output_mode", "json"))
        def HttpGet getResultsRequest = new HttpGet(URIUtils.createURI(host.schemeName, host.hostName, host.port, "${searchJobURL}/${searchID}/results", URLEncodedUtils.format(qparams, "UTF-8"), null))
        getResultsRequest.setHeader("Authorization", "Splunk ${sessionKey}")

        try {
            log.debug("Retrieving results of Splunk search job with id=${searchID}")
            def response = restClient.execute(getResultsRequest)
            if (response.getStatusLine().getStatusCode() == 200) {
                def JSONObject answer = jsonSlurper.parseText(response.getEntity().getContent().getText()) as JSONObject
                def JSONArray results = answer.getJSONArray("results")
                results.asList()
            } else {
                println("error during obtaining results")
                []
            }
        } catch (Exception ex) {
            throw new RuntimeException("An error occured during obtaining results of search job using Splunk REST API: ${ex.getMessage()}", ex.getCause())
        }
    }
}

/**
 * Splunk search job statuses
 */
public enum SearchJobStatus {
    DONE("DONE"),
    FAILED("FAILED"),
    IN_PROGRESS("IN_PROGRESS")

    private def String value

    public SearchJobStatus(String value) {
        this.value = value
    }
}

public enum PieColor {
    COL_003300("003300", 0),
    COL_006600("006600", 1),
    COL_009900("009900", 2),
    COL_00CC00("00CC00", 3),
    COL_00FF00("00FF00", 4),
    COL_99FF00("99FF00", 5),
    COL_99CC00("99CC00", 6),
    COL_999900("999900", 7),
    COL_996600("996600", 8),
    COL_993300("993300", 9),
    COL_990000("990000", 10),
    COL_CC0000("CC0000", 11)

    private def String code
    private def Integer order

    def PieColor(String code, Integer order) {
        this.code = code
        this.order = order
    }

    def String getCode() {
        code
    }

    def Integer getOrder() {
        order
    }

    def PieColor next2() {
        this.next().next()
    }

    def PieColor next3() {
        this.next().next().next()
    }
}