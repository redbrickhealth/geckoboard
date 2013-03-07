geckoboard
==========

Scripts to post to Geckoboard

syncJira.sh 
-----------

Designed for retrieving metrics from Jira Server via REST API and pushing them to dashboard on Geckoboard.  
Geckoboard dashboard shared URL at the moment is: https://rbsync.geckoboard.com/dashboard/D351DCB27F291EB3/ 

Usage: syncJira.sh [options]   
Options:  
-u,--username. Required. Username used to access Jira server.  
-p,--password. Required. Password for specified user.  
-h,--host. Optional. Base URL of Jira server. Default is http://localhost:8080.  
-P,--project-name'. Required. Project name to retrieve Jira issue metrics.  

Example:  
Show issue metrics for project 'ecosystem':  

$syncJira.sh -u user -p password -P ecosystem   

syncCrucible.sh 
---------------

Designed for retrieving metrics from Crucible Server via REST API and pushing them to dashboard on Geckoboard.  
Geckoboard dashboard shared URL at the moment is: https://rbsync.geckoboard.com/dashboard/7E14ED09BC516B8E/

Usage: syncCrucible.sh [options]  
Options:  
-u,--username. Required. Username used to access Jira server.  
-p,--password. Required. Password for specified user.  
-h,--host. Optional. Base URL of Crucible server. Defaultsis http://localhost:8060.  
-P,--project-name'. Required. Project name to retrieve Crucible review metrics.  

Example:    
Show review metrics for project 'CR':    

$syncCrucible.sh -u user -p password -P CR     

syncSplunk.sh 
-------------

Designed for retrieving metrics from Splunk Server via REST API and pushing them to dashboard on Geckoboard.  
Geckoboard dashboard shared URL at the moment is: https://rbsync.geckoboard.com/dashboard/5E4E7BBF0A18DC83/  

Usage: syncSplunk.sh [options]  
Options:  
-u,--username. Required. Username used to access Crucible server.  
-p,--password. Required. Password for specified username.  
-h,--host. Optional. Base URL of Splunk server. Default is: https://localhost:8089.  
-e,--error-id. Optional. Identifier to search Error logs using Splunk. Default is 'ERROR'. Use with -r option to use it as regex expression.  
-r,--regex. Optional. Allow using identifier from -e option or its default value as regular expression pattern.  
-s,--sourcetype. Optional. Value for 'sourcetype' parameter of Splunk search filtering. All source types used for search by default: '*'.  
-S,--source. Optional. Value for 'source' parameter of Splunk search filtering. All sources used for search by default: '*'.  
-f,--fields. Optional. Comma-separated list of fields used to perform Splunk search. Field filter is not specified by default.  
-t,--time. Optional. Value of Splunk search start time parameter (earliest_time). Default is '-4h' that means 'for last 4 hours'. See Splunk docs for details.  

Example:  
Show number of error logs for last 12 hours and set the source type to "custom":  

$syncSplunk.sh -u user -p password -t '"-12h"' -s custom  