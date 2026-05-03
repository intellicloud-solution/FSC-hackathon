public with sharing class GetTodaysMarketInsightsActionfinal {

    public class InputParams {
        @InvocableVariable(label='Share Names (Optional)')
        public List<String> shareNames;
    }

    public class OutputParams {
        @InvocableVariable(label = 'Market Insights Summary')
        public String marketInsightsSummary;

        @InvocableVariable(label = 'Total Events Found')
        public Integer totalCount;

        @InvocableVariable(label = 'Success')
        public Boolean isSuccess;

        @InvocableVariable(label = 'Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label       = 'Get Market Insights (By Share)'
        description = 'Fetches Market Events for TCS, Infosys, SBI (no date filter).'
        category    = 'Market Intelligence'
    )
    public static List<OutputParams> getMarketInsights(List<InputParams> inputs) {

        List<OutputParams> results = new List<OutputParams>();
        OutputParams output = new OutputParams();
        output.isSuccess = true;

        try {
            // Default Shares
            List<String> targetShares = new List<String>{ 'TCS', 'Infosys', 'SBI' };

            // Override from Flow input
            if (inputs != null && !inputs.isEmpty()) {
                if (inputs[0].shareNames != null && !inputs[0].shareNames.isEmpty()) {
                    targetShares = inputs[0].shareNames;
                }
            }

            // ✅ NO DATE FILTER HERE
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
                WHERE  Share_Name__c IN :targetShares
                ORDER  BY Share_Name__c ASC, Event_Date_Time__c DESC NULLS LAST
            ];

            if (events.isEmpty()) {
                output.totalCount = 0;
                output.marketInsightsSummary =
                    '📊 Market Insights\n\n' +
                    'No market events found for selected shares.';
                results.add(output);
                return results;
            }

            // Group by Share
            Map<String, List<Market_Event__c>> eventsByShare = new Map<String, List<Market_Event__c>>();

            for (Market_Event__c evt : events) {
                if (!eventsByShare.containsKey(evt.Share_Name__c)) {
                    eventsByShare.put(evt.Share_Name__c, new List<Market_Event__c>());
                }
                eventsByShare.get(evt.Share_Name__c).add(evt);
            }

            // Build Summary
            List<String> summaryLines = new List<String>();
            summaryLines.add('📊 Market Insights\n');

            for (String share : targetShares) {

                if (!eventsByShare.containsKey(share)) continue;

                summaryLines.add('━━━━━━━━━━━━━━━━━━━━━━━━');
                summaryLines.add('🔹 ' + share);
                summaryLines.add('━━━━━━━━━━━━━━━━━━━━━━━━');

                for (Market_Event__c evt : eventsByShare.get(share)) {

                    summaryLines.add(
                        '• Event          : ' + evt.Name + '\n' +
                        '  Type           : ' + (evt.Event_Type__c != null ? evt.Event_Type__c : 'N/A') + '\n' +
                        '  Severity       : ' + (evt.Severity__c != null ? evt.Severity__c : 'N/A') + '\n' +
                        '  Threshold      : ' + (evt.Trigger_Threshold__c != null ? evt.Trigger_Threshold__c + '%' : 'N/A') + '\n' +
                        '  Summary        : ' + (evt.Summary__c != null ? evt.Summary__c : 'N/A') + '\n' +
                        '  Recommendation : ' + (evt.Agent_Recommendation__c != null ? evt.Agent_Recommendation__c : 'N/A')
                    );
                }
            }

            summaryLines.add('\n━━━━━━━━━━━━━━━━━━━━━━━━');
            summaryLines.add('Total Events : ' + events.size());

            output.totalCount = events.size();
            output.marketInsightsSummary = String.join(summaryLines, '\n');

        } catch (Exception ex) {
            output.isSuccess = false;
            output.errorMessage =
                'Error: ' + ex.getMessage() +
                ' | Line: ' + ex.getLineNumber();
        }

        results.add(output);
        return results;
    }
}