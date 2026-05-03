public class AgentforceMarketAction {
    
    @InvocableMethod(
        label='Get Stock Market Quote'
        description='Fetches live price and change % for a given stock symbol'
    )
    public static List<String> getMarketQuote(List<String> symbols) {
        List<String> results = new List<String>();
        
        for (String symbol : symbols) {
            results.add(MarketDataService.getStockQuote(symbol));
        }
        
        return results;
    }
}