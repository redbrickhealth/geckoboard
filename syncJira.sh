#! /usr/bin/env groovy

import com.atlassian.jira.rest.client.api.JiraRestClient
import com.atlassian.jira.rest.client.api.MetadataRestClient
import com.atlassian.jira.rest.client.api.SearchRestClient
import com.atlassian.jira.rest.client.api.domain.Issue
import com.atlassian.jira.rest.client.internal.async.AsynchronousJiraRestClientFactory
import groovy.json.JsonSlurper
import net.sf.json.JSONObject
import org.apache.http.client.HttpClient
import org.apache.http.client.methods.HttpPost
import org.apache.http.entity.ContentType
import org.apache.http.entity.StringEntity
import org.apache.http.impl.client.DefaultHttpClient
import org.apache.http.impl.conn.PoolingClientConnectionManager

@GrabResolver(name = 'atlassian-public', root = 'https://maven.atlassian.com/content/repositories/atlassian-public/')
@Grapes([
    @Grab(group = 'org.slf4j', module = 'slf4j-simple', version = '1.7.2'),
    @Grab(group = 'com.atlassian.jira', module = 'jira-rest-java-client-api', version = '2.0.0-m11'),
    @Grab(group = 'com.atlassian.jira', module = 'jira-rest-java-client-core', version = '2.0.0-m11'),
    @Grab(group = 'org.codehaus.groovy.modules.http-builder', module = 'http-builder', version = '0.6')
])

def startTime = System.currentTimeMillis()
System.out.println(" [Initializing...] ")

// Define constants
def String defaultHost = "http://localhost:8080"
def Integer max = 150
def boardBasePushURL = "https://push.geckoboard.com/v1/send/"
// Account api key
def apiKey = "8b27afebd6aa68661e4ad88488239c76"

// Widget keys (type, description)
// Number. Displays total number of created issues.
def issuesTotalWidgetKey = "28094-2a8ba667-23cf-418a-96d6-d3663604963d"
// Text. Displays project name.
def projectNameWidgetKey = "28094-79e63d9b-9a88-4181-be8a-3264cbfad8f8"
// Text. Displays last update time.
def updateTimeWidgetKey = "28094-fa3a4b62-a827-4d93-a1bb-a5d976bcaf7a"
// RAG. Displays resolution metrics.
def issuesByResolutionWidgetKey = "28094-3a105bc6-e237-42ab-aa87-f43e6e7ed52d"
// RAG. Display status metrics.
def issuesByStatusWidgetKey = "28094-ac98d544-ca46-4d22-9100-019e75fa5f3e"
// Pie chart. Displays metircs for unresolved issues by type.
def issuesByTypeWidgetKey = "28094-aadf9ac2-0c86-4552-8f98-7842a4014c61"
// Pie chart. Displays metircs for unresolved issues by priority.
def issuesByPriorityWidgetKey = "28094-096b462f-d3cd-4fbf-9b4b-84560280388a"

// regular expressions for status metrics
def statusRed = "new|open|reopened"
def statusAmber = "\\w*?\\s*?in progress|product sign off"
def statusGreen = "closed|resolved"

/**
 * Issues search request 'fields' parameter value. 'summary', 'issuetype', 'created',
 * 'updated', 'project' and 'status' are required.
 */
def String fields = "summary,issuetype,created,updated,project,status,resolution,priority"

// Parse command line options
def CliBuilder cli = new CliBuilder(usage: 'syncJira.sh [options] ', header: 'Options:')
cli.with {
    u(longOpt: 'username', args: 1, required: true, argName: 'username', "Username used to access Jira server")
    p(longOpt: 'password', args: 1, required: true, argName: 'password', "Password for specified username")
    h(longOpt: 'host', args: 1, required: false, argName: 'host', "Base URL of Jira server. Default is: \"${defaultHost}\"")
    P(longOpt: 'project-name', args: 1, required: true, argName: 'project name', "Project name to retrieve issue metrics")
}
def options = cli.parse(args)
if (!options) {
    return
}
def URI jiraBaseURL = new URI(options.getInner().getOptionValue('h', defaultHost))
def String username = options.getInner().getOptionValue('u')
def String password = options.getInner().getOptionValue('p')
def String project = options.getInner().getOptionValue('P')

// Create and initialize clients

// Jira client
def AsynchronousJiraRestClientFactory factory = new AsynchronousJiraRestClientFactory()
def JiraRestClient jiraClient = factory.createWithBasicHttpAuthentication(jiraBaseURL, username, password)
def SearchRestClient searchClient = jiraClient.getSearchClient()
def MetadataRestClient metadataClient = jiraClient.getMetadataClient()

// Geckoboard client
def pushClient = new GeckoboardPushClient(apiKey, boardBasePushURL)

// Syncing
System.out.println(" [Start polling data from JIRA] ")

try {
    // Obtaining total number of issues
    def Long total = searchClient.searchJql("project=${project}", 0, 0, fields).claim().getTotal().toLong()
    def pages = new IntRange(0, total.intValue()).step(max)

    // Set timestamp
    def Date timestamp = new Date()

    // Obtaining issues data
    def Issue[] issues = pages.collect { startAt ->
        def List<Issue> issuesOnPage = new LinkedList<Issue>()
        def issueIterator = searchClient.searchJql("project=${project}", max, startAt, fields).claim().getIssues().iterator()
        while (issueIterator.hasNext()) {
            issuesOnPage.add(issueIterator.next())
        }
        issuesOnPage
    }.grep { it != null }.flatten().toArray(new Issue[0])

    // Obtaining list of issue priority constants
    def priorities = metadataClient.getPriorities().claim().collect {it.name.toLowerCase()}

    // Obtaining list of issue type constants
    def types = metadataClient.getIssueTypes().claim().collect {it.name.toLowerCase()}

    // Splitting resolved and unresolved issues
    def unresolvedIssues = issues.grep { it.resolution == null}
    def resolvedIssues = issues.grep { it.resolution != null}

    // Calculating issue status metrics
    def Integer open = issues.grep { it.getStatus().getName().toLowerCase().matches(statusRed)}.size()
    def Integer inProgress = issues.grep { it.getStatus().getName().toLowerCase().matches(statusAmber)}.size()
    def Integer closed = issues.grep { it.getStatus().getName().toLowerCase().matches(statusGreen)}.size()

    // Calculating unresolved issues by type metrics
    def PieColor color = PieColor.COL_CC0000
    def typesChartData = types.collect { name ->
        color = color.next()
        def Integer data = unresolvedIssues.grep {it.getIssueType().getName().equalsIgnoreCase(name)}.size()
        new PieItem(data, "${name} (${data})", color.getCode())
    }

    // Calculating unresolved issues by priority metrics
    color = PieColor.COL_003300
    def priorityChartData = priorities.collect { name ->
        color = color.previous()
        def Integer data = unresolvedIssues.grep {it.getPriority().getName().equalsIgnoreCase(name)}.size()
        new PieItem(data, "${name} (${data})", color.getCode())
    }

    // Start pushing metrics onto dashboard on Geckoboard
    System.out.println(" [Metrics obtained. Start pushing data to JIRA dashboard on Geckoboard] ")

    System.out.print(" [Push Number data: issues created] ")
    pushClient.pushData(issuesTotalWidgetKey, WidgetType.NUMBER,
            [new NumberItem(issues.size(), "Issues total")]
    )

    System.out.print(" [Push Text data: project name] ")
    pushClient.pushData(projectNameWidgetKey, WidgetType.TEXT,
            [new TextItem(project, TextWidgetDisplayType.INFO)]
    )

    System.out.print(" [Push RAG data: issues by resolution] ")
    pushClient.pushData(issuesByResolutionWidgetKey, WidgetType.RAG_COLUMNS,
            [new NumberItem(unresolvedIssues.size(), "unresolved"), new NumberItem(resolvedIssues.size(), "resolved")]
    )

    System.out.print(" [Push RAG data: issues by status] ")
    pushClient.pushData(issuesByStatusWidgetKey, WidgetType.RAG_COLUMNS,
            [new NumberItem(open, "new"), new NumberItem(inProgress, "in progress"), new NumberItem(closed, "closed")]
    )

    System.out.print(" [Push PieChart data: unresolved issues by type] ")
    pushClient.pushData(issuesByTypeWidgetKey, WidgetType.PIE_CHART, typesChartData)

    System.out.print(" [Push PieChart data: unresolved issues by priority] ")
    pushClient.pushData(issuesByPriorityWidgetKey, WidgetType.PIE_CHART, priorityChartData)

    System.out.print(" [Push update time data] ")
    pushClient.pushData(updateTimeWidgetKey, WidgetType.TEXT,
            [new TextItem(timestamp.toGMTString(), TextWidgetDisplayType.INFO)]
    )

    jiraClient.destroy()
} catch (Exception ex) {
    System.err.println("${ex.getMessage()}\n${ex.getCause()})")
}

System.out.println(" [JIRA metrics sync task completed. Elapsed time: ${System.currentTimeMillis() - startTime} ms] ")
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
