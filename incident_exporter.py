import csv
import json
import requests

def fetch_incidents(api_url, app_key, start_time, end_time, limit=20):
    search_after_ctx = None  # 初始游标为空
    has_next_page = True
    all_items = []

    while has_next_page:
        # 创建请求体
        payload = {
            "search_after_ctx": search_after_ctx,
            "limit": limit,
            "start_time": start_time,
            "end_time": end_time
        }

        # 发送请求，app_key作为Query参数
        params = {
            "app_key": app_key
        }
        response = requests.post(api_url, params=params, json=payload)

        if response.status_code != 200:
            print(f"Error: {response.status_code} - {response.text}")
            break

        data = response.json()

        # 处理响应数据
        items = data.get("data", {}).get("items", [])
        search_after_ctx = data.get("data", {}).get("search_after_ctx")
        has_next_page = data.get("data", {}).get("has_next_page", False)

        # 合并数据
        all_items.extend(items)

        # 打印当前批次获取的数据
        print(f"Fetched {len(items)} incidents, next search_after_ctx: {search_after_ctx}")

        # 如果没有更多数据，结束循环
        if not has_next_page:
            break

    return all_items

def export_to_csv(incidents, output_file, fieldnames):
    if incidents:
        with open(output_file, 'w', newline='', encoding='utf-8') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()

            # 确保每个事件都可以正确写入，即使有些字段为空
            for incident in incidents:
                writer.writerow({field: incident.get(field, "") for field in fieldnames})

        print(f"Data exported to {output_file}")
    else:
        print("No incidents found to export.")

if __name__ == "__main__":
    api_url = "https://api.flashcat.cloud/incident/list"  # 替换为实际的 API URL
    app_key = "8a7944e3653c53c4a4ad7a94194bda48973"  # 替换为实际的 app_key

    # 设置时间范围，单位为秒（Unix时间戳）
    start_time = 1725120000  # 示例起始时间
    end_time = 1725941674    # 示例结束时间

    # 定义你想要的 CSV 字段名顺序
    fieldnames = ["num","incident_id","title","incident_severity","incident_status","progress","channel_id","channel_name","labels","fields","alert_cnt","start_time","last_time","end_time","ack_time","close_time","creator_id","closer_id","ever_muted","group_method","data_source_id","data_source_type","detail_url","assigned_to","responders","description","impact","root_cause","resolution"]

    # 获取所有事件
    incidents = fetch_incidents(api_url, app_key, start_time, end_time)

    # 将事件数据导出为CSV
    if incidents:
        output_file = "incidents_export.csv"
        export_to_csv(incidents, output_file, fieldnames)
    else:
        print("No incidents to export.")
