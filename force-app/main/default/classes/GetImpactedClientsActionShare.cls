public class GetImpactedClientsActionShare {

    // ── Input ──────────────────────────────────────────────────────────────────
    public class InputParams {
        @InvocableVariable(
            label       = 'Share Name'
            description = 'The Share Name to filter impacted clients (e.g. TCS)'
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

        @InvocableVariable(label = 'Total Gain Loss')
        public Decimal totalGainLoss;

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
        description = 'Given a Share Name, returns all impacted clients with account info, gain/loss, and preferred communication channel.'
        category    = 'Market Intelligence'
    )
    public static List<OutputParams> getImpactedClients(List<InputParams> inputs) {

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
                           Summary__c,
                           Agent_Recommendation__c,
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

                // ── Collect Market Event Ids ───────────────────────────────────
                Set<Id> marketEventIds = new Set<Id>();
                Map<Id, Market_Event__c> eventMap = new Map<Id, Market_Event__c>();
                for (Market_Event__c evt : events) {
                    marketEventIds.add(evt.Id);
                    eventMap.put(evt.Id, evt);
                }

                // ── Query Impacted Clients ─────────────────────────────────────
                List<Client_Market_Impact__c> impacts = [
                    SELECT Id,
                           Account__r.Id,
                           Account__r.Name,
                           Account__r.PersonEmail,
                           Account__r.PersonContactId,
                           Account__r.Phone,
                           Share_Name__c,
                           Market_Event__c,
                           Market_Event__r.Name,
                           Market_Event__r.Share_Name__c,
                           Impact_Type__c,
                           Gain_Loss__c,
                           Communication_Status__c,
                           Preferred_channel__c
                    FROM   Client_Market_Impact__c
                    WHERE  Share_Name__c = :input.shareName
                    AND    Market_Event__c IN :marketEventIds
                    ORDER  BY Gain_Loss__c DESC NULLS LAST
                ];

                if (impacts.isEmpty()) {
                    output.isSuccess              = true;
                    output.totalCount             = 0;
                    output.totalGainLoss          = 0;
                    output.impactedClientsSummary = 'No impacted clients found for Share Name: ' + input.shareName;
                    output.clientRecordsJson      = '[]';
                    results.add(output);
                    continue;
                }

                // ── Build Summary & JSON ───────────────────────────────────────
                Decimal totalGainLoss     = 0;
                List<String> jsonRecords  = new List<String>();
                List<String> summaryLines = new List<String>();

                for (Client_Market_Impact__c impact : impacts) {
                    Decimal gainLoss = impact.Gain_Loss__c != null ? impact.Gain_Loss__c : 0;
                    totalGainLoss += gainLoss;

                    // Human-readable summary line
                    summaryLines.add(
                        '• ' + impact.Account__r.Name +
                        ' | Share: '       + (impact.Share_Name__c                 != null ? impact.Share_Name__c                 : 'N/A') +
                        ' | Market Event: '+ (impact.Market_Event__r.Name          != null ? impact.Market_Event__r.Name           : 'N/A') +
                        ' | Impact: '      + (impact.Impact_Type__c                != null ? impact.Impact_Type__c                 : 'N/A') +
                        ' | Gain/Loss: ₹'  + gainLoss.setScale(2).toPlainString() +
                        ' | Channel: '     + (impact.Preferred_channel__c          != null ? impact.Preferred_channel__c           : 'N/A') +
                        ' | Comm Status: ' + (impact.Communication_Status__c       != null ? impact.Communication_Status__c        : 'Pending')
                    );

                    // JSON record
                    jsonRecords.add(
                        '{"accountId":"'            + impact.Account__r.Id                              + '",' +
                        '"accountName":"'           + escapeJson(impact.Account__r.Name)                + '",' +
                        '"email":"'                 + escapeJson(impact.Account__r.PersonEmail)         + '",' +
                        '"personContactId":"'       + escapeJson(impact.Account__r.PersonContactId)     + '",' +
                        '"phone":"'                 + escapeJson(impact.Account__r.Phone)               + '",' +
                        '"shareName":"'             + escapeJson(impact.Share_Name__c)                  + '",' +
                        '"marketEventName":"'       + escapeJson(impact.Market_Event__r.Name)           + '",' +
                        '"marketEventShareName":"'  + escapeJson(impact.Market_Event__r.Share_Name__c)  + '",' +
                        '"impactType":"'            + escapeJson(impact.Impact_Type__c)                 + '",' +
                        '"gainLoss":'               + gainLoss                                           + ','  +
                        '"communicationStatus":"'   + escapeJson(impact.Communication_Status__c)        + '",' +
                        '"preferredChannel":"'      + escapeJson(impact.Preferred_channel__c)           + '"}'
                    );
                }

                // ── Populate Output ────────────────────────────────────────────
                output.totalCount        = impacts.size();
                output.totalGainLoss     = totalGainLoss;
                output.clientRecordsJson = '[' + String.join(jsonRecords, ',') + ']';

                output.impactedClientsSummary =
                    'Share Name             : ' + input.shareName + '\n' +
                    'Total Impacted Clients : ' + impacts.size() + '\n' +
                    'Total Gain / Loss      : ₹' + totalGainLoss.setScale(2).toPlainString() + '\n\n' +
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