#! /usr/bin/env groovy

import groovy.json.JsonSlurper
import net.sf.json.JSONObject
import org.apache.http.HttpEntity
import org.apache.http.HttpHost
import org.apache.http.NameValuePair
import org.apache.http.client.HttpClient
import org.apache.http.client.entity.UrlEncodedFormEntity
import org.apache.http.client.methods.HttpGet
import org.apache.http.client.methods.HttpPost
import org.apache.http.client.utils.URIUtils
import org.apache.http.client.utils.URLEncodedUtils
import org.apache.http.entity.ContentType
import org.apache.http.entity.StringEntity
import org.apache.http.impl.client.DefaultHttpClient
import org.apache.http.impl.conn.PoolingClientConnectionManager
import org.apache.http.message.BasicNameValuePair

@Grapes([
    @Grab(group = 'org.codehaus.groovy.modules.http-builder', module = 'http-builder', version = '0.6')
])

def startTime = System.currentTimeMillis()
System.out.println(" [Initializing...] ")

// Define constants
def String defaultHost = "http://localhost:8060"
def Integer max = 150
def boardBasePushURL = "https://push.geckoboard.com/v1/send/"
// Account api key
def apiKey = "8b27afebd6aa68661e4ad88488239c76"

// Widget keys (type, description)
// Text. Displays project name.
def projectNameWidgetKey = "28094-6a60db44-8f91-43ea-8bec-25bda45b7393"
// Text. Displays last update time.
def updateTimeWidgetKey = "28094-b3a611df-879c-4c59-a303-e6eba7c2e40c"
// Number. Displays total number of created reviews.
def totalReviewsWidgetKey = "28094-74422476-ff01-470e-9bc6-85a413e31f27"
// Number. Displays number of abandoned reviews.
def abandonedReviewsWidgetKey = "28094-e2c306e3-f3b6-4429-8f37-de816b1ba9f2"
// Number. Displays number of rejected reviews.
def rejectedReviewsWidgetKey = "28094-67912e31-4a43-4d2e-98f8-4da2f62df5f3"
// RAG. Display review status metrics.
def reviewsByStateWidgetKey = "28094-47e63541-04f8-4ff5-8be2-ad9e3c2d3d7d"
// Pie chart. Displays review state metircs.
def reviewsByStateCharWidgetKey = "28094-4e03a7d7-ca57-4571-b2e7-27b9a25ef715"

// Allowed review states
def List<String> states = ["Draft", "Approval", "Review", "Summarize", "Closed", "Dead", "Rejected", "Unknown"]

// Parse command line options
def CliBuilder cli = new CliBuilder(usage: 'syncCrucible.sh [options] ', header: 'Options:')
cli.with {
    u(longOpt: 'username', args: 1, required: true, argName: 'username', "Username used to access Crucible server")
    p(longOpt: 'password', args: 1, required: true, argName: 'password', "Password for specified username")
    h(longOpt: 'host', args: 1, required: false, argName: 'host', "Base URL of Crucible server. Default is: \"${defaultHost}\"")
    P(longOpt: 'project-name', args: 1, required: true, argName: 'project name', "Project name to retrieve review metrics")
}
def options = cli.parse(args)
if (!options) {
    return
}
def URI crucibleBaseURL = new URI(options.getInner().getOptionValue('h', defaultHost))
def String username = options.getInner().getOptionValue('u')
def String password = options.getInner().getOptionValue('p')
def String project = options.getInner().getOptionValue('P')

// Create and initialize clients

// Crucible client
def crucibleClient = new CrucibleClient(crucibleBaseURL)

// Geckoboard client
def pushClient = new GeckoboardPushClient(apiKey, boardBasePushURL)

// Syncing
System.out.println(" [Start polling data from CRUCIBLE] ")

try {

    // authenticate on Crucible server
    crucibleClient.authenticate(username, password)

    // Set timestamp
    def Date timestamp = new Date()

    // get total number of created reviews
    def Long total = crucibleClient.get("/rest-service/reviews-v1/filter", ["project": project], [:]).optJSONArray("reviewData").size()

    // calculate number of reviews by state
    def reviewsByState = states.collect { state ->
        def size = crucibleClient.get("/rest-service/reviews-v1/filter", ["project": project, "states": state], [:]).optJSONArray("reviewData").size()
        ["state" : state, "size" : size]
    }

    // Start pushing metrics onto dashboard on Geckoboard
    System.out.println(" [Metrics obtained. Start pushing data to CRUCIBLE dashboard on Geckoboard] ")

    System.out.print(" [Push Text data: project name] ")
    pushClient.pushData(projectNameWidgetKey, WidgetType.TEXT,
            [new TextItem(project, TextWidgetDisplayType.INFO)]
    )

    System.out.print(" [Push Number data: total reviews] ")
    pushClient.pushData(totalReviewsWidgetKey, WidgetType.NUMBER,
            [new NumberItem(total, "Total reviews")]
    )

    System.out.print(" [Push RAG data: reviews status] ")
    pushClient.pushData(reviewsByStateWidgetKey, WidgetType.RAG_COLUMNS,
            [
                    new NumberItem(reviewsByState.find {it.state.equalsIgnoreCase("review")}.size, "open"),
                    new NumberItem(reviewsByState.find {it.state.equalsIgnoreCase("draft")}.size, "draft"),
                    new NumberItem(reviewsByState.find {it.state.equalsIgnoreCase("closed")}.size, "closed")
            ]
    )

    System.out.print(" [Push Number data: abandoned reviews] ")
    pushClient.pushData(abandonedReviewsWidgetKey, WidgetType.NUMBER,
            [new NumberItem(reviewsByState.find {it.state.equalsIgnoreCase("dead")}.size, "Abandoned reviews")]
    )

    System.out.print(" [Push Number data: rejected reviews] ")
    pushClient.pushData(rejectedReviewsWidgetKey, WidgetType.NUMBER,
            [new NumberItem(reviewsByState.find {it.state.equalsIgnoreCase("rejected")}.size, "Rejected reviews")]
    )

    // build data for pie chart: reviews by state
    def PieColor color = PieColor.COL_CC0000
    def statusChartData = reviewsByState.collect { it ->
        color = color.next()
        def size = it.get("size") as Long
        def state = it.get("state") as String
        new PieItem(size, "${state} (${size})", color.getCode())
    }

    System.out.print(" [Push PieChart data: reviews by status] ")
    pushClient.pushData(reviewsByStateCharWidgetKey, WidgetType.PIE_CHART, statusChartData)

    System.out.print(" [Push update time data] ")
    pushClient.pushData(updateTimeWidgetKey, WidgetType.TEXT,
            [new TextItem(timestamp.toGMTString(), TextWidgetDisplayType.INFO)]
    )
} catch (Exception ex) {
    System.err.println("${ex.getMessage()}\n${ex.getCause()})")
}

System.out.println(" [CRUCIBLE reviews metrics sync task completed. Elapsed time: ${System.currentTimeMillis() - startTime} ms] ")
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
        def HttpPost pushRequest = new HttpPost("${pushAPIBaseURL}${widgetKey}")
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
 * REST Client for Crucible.
 */
class CrucibleClient {

    private def HttpClient restClient
    private def String basePath
    private def String authPath
    private def String token
    private def String user

    private def slurper = new JsonSlurper()

    CrucibleClient(basePath) {
        this.restClient = new DefaultHttpClient()
        this.basePath = basePath
        this.authPath = "${basePath}/rest-service/auth-v1/login"
    }

    def String authenticate(String user, String password) {

        def HttpPost postRequest = new HttpPost(authPath)

        postRequest.setEntity(new UrlEncodedFormEntity([new BasicNameValuePair("userName", user), new BasicNameValuePair("password", password)]))

        postRequest.setHeader("Accept", "application/json")
        postRequest.setHeader("Content-Type", "application/x-www-form-urlencoded")

        try {
            def authResponse = restClient.execute(postRequest).entity.content.text
            token = slurper.parseText(authResponse).token
            this.user = user
            println("Info:  Authentication completed")
            return token
        } catch (Exception ex) {
            println("Error: Authentication failed")
            return null
        }
    }

    def JSONObject get(String uri, Map<String, String> params, Map<String, String> headers) {
        def HttpHost host = URIUtils.extractHost(new URI(basePath))
        def List<NameValuePair> queryParams = params.collect() { name, value -> new BasicNameValuePair(name, value)}
        queryParams.add(new BasicNameValuePair("FEAUTH", token))

        def HttpGet getRequest = new HttpGet(URIUtils.createURI(host.schemeName, host.hostName, host.port, uri, URLEncodedUtils.format(queryParams, "UTF-8"), null))

        getRequest.setHeader("Accept", "application/json")
        getRequest.setHeader("Content-Type", "application/json")

        try {
            def response = restClient.execute(getRequest)
            return slurper.parseText(response.entity.content.text) as JSONObject
        } catch (Exception ex) {
            println("Error: ${ex.getMessage()}")
            return null
        }
    }

    def JSONObject post(String uri, Map<String, String> params, Map<String, String> headers, HttpEntity body) {
        def HttpHost host = URIUtils.extractHost(new URI(basePath))
        def List<NameValuePair> queryParams = params.collect() { name, value -> new BasicNameValuePair(name, value)}
        queryParams.add(new BasicNameValuePair("FEAUTH", token))

        def HttpPost postRequest = new HttpPost(URIUtils.createURI(host.schemeName, host.hostName, host.port, uri, URLEncodedUtils.format(queryParams, "UTF-8"), null))

        postRequest.setEntity(body)

        postRequest.setHeader("Accept", "application/json")
        postRequest.setHeader("Content-Type", "application/json")

        try {
            def response = restClient.execute(postRequest)
            return slurper.parseText(response.entity.content.text) as JSONObject
        } catch (Exception ex) {
            println("Error: ${ex.getMessage()}")
            return null
        }
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
