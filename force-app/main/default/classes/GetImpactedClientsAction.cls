public class GetImpactedClientsAction {

    // ── Input ──────────────────────────────────────────────────────────────────
    public class InputParams {
        @InvocableVariable(
            label       = 'Market Event Name'
            description = 'The Name of the Market_Event__c record (e.g. ME-0001)'
            required    = true
        )
        public String marketEventName;
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
        label       = 'Get Impacted Clients by Market Event'
        description = 'Given a Market Event Name, returns all impacted clients with account info, share name, estimated loss, and preferred communication channel.'
        category    = 'Market Intelligence'
    )
    public static List<OutputParams> getImpactedClients(List<InputParams> inputs) {

        List<OutputParams> results = new List<OutputParams>();

        for (InputParams input : inputs) {
            OutputParams output = new OutputParams();
            output.isSuccess = true;

            try {
                // ── Validate Input ─────────────────────────────────────────────
                if (String.isBlank(input.marketEventName)) {
                    output.isSuccess    = false;
                    output.errorMessage = 'Market Event Name cannot be blank.';
                    results.add(output);
                    continue;
                }

                // ── Query Market Event ─────────────────────────────────────────
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
                    WHERE  Name = :input.marketEventName
                    LIMIT  1
                ];

                if (events.isEmpty()) {
                    output.isSuccess    = false;
                    output.errorMessage = 'No Market Event found for Name: ' + input.marketEventName;
                    results.add(output);
                    continue;
                }

                Market_Event__c mktEvent = events[0];

                // ── Query Impacted Clients ─────────────────────────────────────
                // ← Updated: uses Account__r instead of Contact__r
                // ← Added:   Account__r.Id, Share_Name__c, Market_Event__r.Share_Name__c
                List<Client_Market_Impact__c> impacts = [
                    SELECT Id,
                           Account__c,
                           Account__r.Id,
                           Account__r.Name,
                           Account__r.PersonEmail,
                           Account__r.PersonContactId,
                           Account__r.Phone,
                           Share_Name__c,
                           Market_Event__c,
                           Market_Event__r.Share_Name__c,
                           Impact_Type__c,
                           Estimated_Loss__c,
                           Portfolio_Exposure__c,
                           Communication_Status__c,
                           Preferred_channel__c
                    FROM   Client_Market_Impact__c
                    WHERE  Market_Event__c = :mktEvent.Id
                    ORDER  BY Estimated_Loss__c DESC NULLS LAST
                ];

                if (impacts.isEmpty()) {
                    output.isSuccess              = true;
                    output.totalCount             = 0;
                    output.totalEstimatedLoss     = 0;
                    output.impactedClientsSummary = 'No impacted clients found for Market Event: ' + mktEvent.Name;
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

                    // Human-readable summary line — now uses Account__r
                    summaryLines.add(
                        '• ' + impact.Account__r.Name +
                        ' | Share: '       + (impact.Share_Name__c               != null ? impact.Share_Name__c               : 'N/A') +
                        ' | Event Share: ' + (impact.Market_Event__r.Share_Name__c != null ? impact.Market_Event__r.Share_Name__c : 'N/A') +
                        ' | Impact: '      + (impact.Impact_Type__c              != null ? impact.Impact_Type__c              : 'N/A') +
                        ' | Loss: ₹'       + loss.setScale(2).toPlainString() +
                        ' | Exposure: '    + exposure.setScale(2).toPlainString() + '%' +
                        ' | Channel: '     + (impact.Preferred_channel__c        != null ? impact.Preferred_channel__c        : 'N/A') +
                        ' | Comm Status: ' + (impact.Communication_Status__c     != null ? impact.Communication_Status__c     : 'Pending')
                    );

                    // JSON record — now uses Account__r fields
                    jsonRecords.add(
                        '{"accountId":"'            + impact.Account__r.Id                              + '",' +
                        '"accountName":"'           + escapeJson(impact.Account__r.Name)                + '",' +
                        '"email":"'                 + escapeJson(impact.Account__r.PersonEmail)         + '",' +
                        '"personContactId":"'       + escapeJson(impact.Account__r.PersonContactId)     + '",' +
                        '"phone":"'                 + escapeJson(impact.Account__r.Phone)               + '",' +
                        '"shareName":"'             + escapeJson(impact.Share_Name__c)                  + '",' +
                        '"marketEventShareName":"'  + escapeJson(impact.Market_Event__r.Share_Name__c)  + '",' +
                        '"impactType":"'            + escapeJson(impact.Impact_Type__c)                 + '",' +
                        '"estimatedLoss":'          + loss                                               + ','  +
                        '"portfolioExposure":'      + exposure                                           + ','  +
                        '"communicationStatus":"'   + escapeJson(impact.Communication_Status__c)        + '",' +
                        '"preferredChannel":"'      + escapeJson(impact.Preferred_channel__c)           + '"}'
                    );
                }

                // ── Populate Output ────────────────────────────────────────────
                output.totalCount         = impacts.size();
                output.totalEstimatedLoss = totalLoss;
                output.clientRecordsJson  = '[' + String.join(jsonRecords, ',') + ']';

                output.impactedClientsSummary =
                    'Market Event  : ' + mktEvent.Name + ' (' + mktEvent.Event_Type__c + ')\n' +
                    'Share Name    : ' + mktEvent.Share_Name__c + '\n' +
                    'Severity      : ' + mktEvent.Severity__c + '\n' +
                    'Summary       : ' + (mktEvent.Summary__c              != null ? mktEvent.Summary__c              : 'N/A') + '\n' +
                    'Recommendation: ' + (mktEvent.Agent_Recommendation__c != null ? mktEvent.Agent_Recommendation__c : 'N/A') + '\n\n' +
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