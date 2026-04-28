public class GetMarketEventsByShareAction {

    // ── Input ──────────────────────────────────────────────────────────────────
    public class InputParams {
        @InvocableVariable(
            label       = 'Share Name'
            description = 'The Share Name (e.g. TCS) to look up all related Market Events'
            required    = true
        )
        public String shareName;
    }

    // ── Output ─────────────────────────────────────────────────────────────────
    public class OutputParams {
        @InvocableVariable(label = 'Market Events Summary')
        public String marketEventsSummary;

        @InvocableVariable(label = 'Total Market Events')
        public Integer totalCount;

        @InvocableVariable(label = 'Market Events JSON')
        public String marketEventsJson;

        @InvocableVariable(label = 'Success')
        public Boolean isSuccess;

        @InvocableVariable(label = 'Error Message')
        public String errorMessage;
    }

    // ── Invocable Entry Point ──────────────────────────────────────────────────
    @InvocableMethod(
        label       = 'Get Market Events by Share Name'
        description = 'Given a Share Name, returns all related Market Events with their type, severity, threshold, and summary.'
        category    = 'Market Intelligence'
    )
    public static List<OutputParams> getMarketEventsByShare(List<InputParams> inputs) {

        List<OutputParams> results = new List<OutputParams>();

        for (InputParams input : inputs) {
            OutputParams output = new OutputParams();
            output.isSuccess = true;

            try {
                // ── Validate Input ─────────────────────────────────────────────
                if (String.isBlank(input.shareName)) {
                    output.isSuccess    = false;
                    output.errorMessage = 'Share Name cannot be blank.';
                    results.add(output);
                    continue;
                }

                // ── Query Market Events by Share Name ──────────────────────────
                List<Market_Event__c> events = [
                    SELECT Id,
                           Name,
                           Event_Type__c,
                           Severity__c,
                           Trigger_Threshold__c,
                           Summary__c,
                           Agent_Recommendation__c,
                           Event_Date_Time__c,
                           Share_Name__c
                    FROM   Market_Event__c
                    WHERE  Share_Name__c = :input.shareName
                    ORDER  BY Event_Date_Time__c DESC NULLS LAST
                ];

                // ── No Events Found ────────────────────────────────────────────
                if (events.isEmpty()) {
                    output.isSuccess          = true;
                    output.totalCount         = 0;
                    output.marketEventsJson   = '[]';
                    output.marketEventsSummary = 'No Market Events found for Share Name: ' + input.shareName;
                    results.add(output);
                    continue;
                }

                // ── Build Summary & JSON ───────────────────────────────────────
                List<String> summaryLines = new List<String>();
                List<String> jsonRecords  = new List<String>();

                for (Market_Event__c evt : events) {

                    // Human-readable summary line
                    summaryLines.add(
                        '• ' + evt.Name +
                        ' | Type: '      + (evt.Event_Type__c          != null ? evt.Event_Type__c          : 'N/A') +
                        ' | Severity: '  + (evt.Severity__c            != null ? evt.Severity__c            : 'N/A') +
                        ' | Threshold: ' + (evt.Trigger_Threshold__c   != null ? evt.Trigger_Threshold__c + '%' : 'N/A') +
                        ' | Date: '      + (evt.Event_Date_Time__c     != null ? evt.Event_Date_Time__c.format() : 'N/A') +
                        ' | Summary: '   + (evt.Summary__c             != null ? evt.Summary__c             : 'N/A')
                    );

                    // JSON record for downstream processing
                    jsonRecords.add(
                        '{"marketEventId":"'       + evt.Id                                          + '",' +
                        '"marketEventName":"'      + escapeJson(evt.Name)                            + '",' +
                        '"eventType":"'            + escapeJson(evt.Event_Type__c)                   + '",' +
                        '"severity":"'             + escapeJson(evt.Severity__c)                     + '",' +
                        '"triggerThreshold":'      + (evt.Trigger_Threshold__c != null ? evt.Trigger_Threshold__c : 0) + ',' +
                        '"summary":"'              + escapeJson(evt.Summary__c)                      + '",' +
                        '"agentRecommendation":"'  + escapeJson(evt.Agent_Recommendation__c)         + '",' +
                        '"eventDateTime":"'        + (evt.Event_Date_Time__c != null ? evt.Event_Date_Time__c.format() : '') + '",' +
                        '"shareName":"'            + escapeJson(evt.Share_Name__c)                   + '"}'
                    );
                }

                // ── Populate Output ────────────────────────────────────────────
                output.totalCount          = events.size();
                output.marketEventsJson    = '[' + String.join(jsonRecords, ',') + ']';
                output.marketEventsSummary =
                    'Share Name          : ' + input.shareName        + '\n' +
                    'Total Market Events : ' + events.size()          + '\n\n' +
                    'Event Details:\n'       + String.join(summaryLines, '\n');

            } catch (Exception ex) {
                output.isSuccess    = false;
                output.errorMessage = 'Error: ' + ex.getMessage() + ' | Line: ' + ex.getLineNumber();
            }

            results.add(output);
        }

        return results;
    }

    // ── Helper ─────────────────────────────────────────────────────────────────
    private static String escapeJson(String val) {
        if (val == null) return '';
        return val.replace('\\', '\\\\').replace('"', '\\"');
    }
}