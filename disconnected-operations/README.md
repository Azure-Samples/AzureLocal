# Disconnected operations samples

Sample artifacts for monitoring Azure Local clusters running in disconnected operations mode.

## point-in-time-metrics.json

Grafana dashboard that surfaces point-in-time metrics for an Azure Local cluster running in disconnected operations mode. The dashboard covers processor, disk, memory, network, TCP, Winsock, services, and scenarios, and queries the local ARM metrics API directly — without requiring connectivity to the Azure public cloud.

### Prerequisites

- Grafana 12.3.0 or later.
- An Azure Local cluster running in disconnected operations mode, with the ARM endpoint reachable from the Grafana host.
- A service principal with permission to read cluster metrics.
- The Azure Local Observability Grafana datasource plugin installed and configured.

### Download and import the dashboard

1. Go to the **disconnected-operations** folder and select **point-in-time-metrics.json**.
1. In the top-right corner, select the **Download raw file** icon. This action saves the file onto your local computer.
1. In Grafana, go to **Dashboards** > **New** > **Import** and upload the file.
1. Select your **Azure Local Monitor** datasource when prompted, then select **Import**.

For full setup, plugin installation, and datasource configuration steps, see [Use Grafana for point-in-time metrics to monitor disconnected operations for Azure Local](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-grafana-monitoring) on Microsoft Learn.

## License

Refer to [LICENSE](../LICENSE.md) for all Licensing information.
