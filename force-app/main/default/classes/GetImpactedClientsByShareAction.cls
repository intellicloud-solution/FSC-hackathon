public class GetImpactedClientsByShareAction {

    // ── Input ──────────────────────────────────────────────────────────────────
    public class InputParams {
        @InvocableVariable(
            label       = 'Share Name'
            description = 'The Share Name (e.g. SBI) to look up impacted clients across all related Market Events'
            required    = true
        )
        public String shareName;
    }

    // ── Output ─────────────────────────────────────────────────────────────────
    public class OutputParams {
        @InvocableVariable(label = 'Impacted Clients Summary')
        public String impactedClientsSummary;

        @InvocableVariable(label = 'Total Impacted Clients')
        public Integer totalCount;

        @InvocableVariable(label = 'Total Estimated Loss')
        public Decimal totalEstimatedLoss;

        @InvocableVariable(label = 'Client Records JSON')
        public String clientRecordsJson;

        @InvocableVariable(label = 'Success')
        public Boolean isSuccess;

        @InvocableVariable(label = 'Error Message')
        public String errorMessage;
    }

    // ── Invocable Entry Point ──────────────────────────────────────────────────
    @InvocableMethod(
        label       = 'Get Impacted Clients by Share Name'
        description = 'Given a Share Name, returns all impacted clients across all related Market Events with their exposure, estimated loss, impact type, and preferred communication channel.'
        category    = 'Market Intelligence'
    )
    public static List<OutputParams> getImpactedClientsByShare(List<InputParams> inputs) {

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
                ];

                if (events.isEmpty()) {
                    output.isSuccess              = false;
                    output.errorMessage           = 'No Market Events found for Share Name: ' + input.shareName;
                    results.add(output);
                    continue;
                }

                // ── Collect all Market Event IDs ───────────────────────────────
                Set<Id> eventIds = new Set<Id>();
                Map<Id, Market_Event__c> eventMap = new Map<Id, Market_Event__c>();
                for (Market_Event__c evt : events) {
                    eventIds.add(evt.Id);
                    eventMap.put(evt.Id, evt);
                }

                // ── Query Impacted Clients across all matching Events ───────────
                List<Client_Market_Impact__c> impacts = [
                    SELECT Id,
                           Market_Event__c,
                           Contact__c,
                           Contact__r.Name,
                           Contact__r.Email,
                           Contact__r.Phone,
                           Impact_Type__c,
                           Estimated_Loss__c,
                           Portfolio_Exposure__c,
                           Communication_Status__c,
                           Preferred_channel__c
                    FROM   Client_Market_Impact__c
                    WHERE  Market_Event__c IN :eventIds
                    ORDER  BY Estimated_Loss__c DESC NULLS LAST
                ];

                if (impacts.isEmpty()) {
                    output.isSuccess              = true;
                    output.totalCount             = 0;
                    output.totalEstimatedLoss     = 0;
                    output.impactedClientsSummary = 'No impacted clients found for Share Name: ' + input.shareName;
                    output.clientRecordsJson      = '[]';
                    results.add(output);
                    continue;
                }

                // ── Build Summary & JSON ───────────────────────────────────────
                Decimal totalLoss         = 0;
                List<String> jsonRecords  = new List<String>();
                List<String> summaryLines = new List<String>();

                for (Client_Market_Impact__c impact : impacts) {
                    Decimal loss     = impact.Estimated_Loss__c     != null ? impact.Estimated_Loss__c     : 0;
                    Decimal exposure = impact.Portfolio_Exposure__c != null ? impact.Portfolio_Exposure__c : 0;
                    totalLoss += loss;

                    Market_Event__c relatedEvent = eventMap.get(impact.Market_Event__c);
                    String eventLabel = relatedEvent != null ? relatedEvent.Name : 'Unknown Event';

                    // Human-readable line for the agent
                    summaryLines.add(
                        '• ' + impact.Contact__r.Name +
                        ' | Event: '     + eventLabel +
                        ' | Impact: '    + (impact.Impact_Type__c           != null ? impact.Impact_Type__c           : 'N/A') +
                        ' | Loss: ₹'    + loss.setScale(2).toPlainString() +
                        ' | Exposure: ' + exposure.setScale(2).toPlainString() + '%' +
                        ' | Channel: '  + (impact.Preferred_channel__c      != null ? impact.Preferred_channel__c      : 'N/A') +
                        ' | Comm Status: ' + (impact.Communication_Status__c != null ? impact.Communication_Status__c : 'Pending')
                    );

                    // JSON record for downstream processing
                    jsonRecords.add(
                        '{"marketEventId":"'      + impact.Market_Event__c                                    + '",' +
                        '"marketEventName":"'     + escapeJson(eventLabel)                                    + '",' +
                        '"contactId":"'           + impact.Contact__c                                         + '",' +
                        '"contactName":"'         + escapeJson(impact.Contact__r.Name)                        + '",' +
                        '"email":"'               + escapeJson(impact.Contact__r.Email)                       + '",' +
                        '"phone":"'               + escapeJson(impact.Contact__r.Phone)                       + '",' +
                        '"impactType":"'          + escapeJson(impact.Impact_Type__c)                         + '",' +
                        '"estimatedLoss":'        + loss                                                       + ','  +
                        '"portfolioExposure":'    + exposure                                                   + ','  +
                        '"communicationStatus":"' + escapeJson(impact.Communication_Status__c)                 + '",' +
                        '"preferredChannel":"'    + escapeJson(impact.Preferred_channel__c)                   + '"}'
                    );
                }

                // ── Build Event Summary Header ─────────────────────────────────
                List<String> eventSummaryLines = new List<String>();
                for (Market_Event__c evt : events) {
                    eventSummaryLines.add(
                        '  - ' + evt.Name +
                        ' (' + evt.Event_Type__c + ')' +
                        ' | Severity: ' + evt.Severity__c +
                        ' | Threshold: ' + (evt.Trigger_Threshold__c != null ? evt.Trigger_Threshold__c + '%' : 'N/A')
                    );
                }

                // ── Populate Output ────────────────────────────────────────────
                output.totalCount         = impacts.size();
                output.totalEstimatedLoss = totalLoss;
                output.clientRecordsJson  = '[' + String.join(jsonRecords, ',') + ']';

                output.impactedClientsSummary =
                    'Share Name           : ' + input.shareName + '\n' +
                    'Related Market Events: ' + events.size() + '\n' +
                    String.join(eventSummaryLines, '\n') + '\n\n' +
                    'Total Impacted Clients : ' + impacts.size() + '\n' +
                    'Total Estimated Loss   : ₹' + totalLoss.setScale(2).toPlainString() + '\n\n' +
                    'Client Details:\n' + String.join(summaryLines, '\n');

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