import requests
import json
from urllib.parse import unquote

class BiApiClient:
    # def __init__(self, access_key_id, access_key_secret, aliyun_id, csrf_token):
    def __init__(self, access_key_id, access_key_secret, csrf_token):
        self.base_url = "https://bi.aliyun.com/api/v2/olap/query"
        self.access_key_id = access_key_id
        self.access_key_secret = access_key_secret
        # self.aliyun_id = aliyun_id
        self.csrf_token = csrf_token
        self.cookie = None
        self.headers = {
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "qbi-report-trace-id": "ab46ddba-8d83-4dbe-bf46-952349c78808",
            "Referer": "https://bi.aliyun.com/dashboard/pc.htm?workspaceId=9f5d8878-f5bd-4c16-bf8b-072a5f48d5d0&pageId=2be4810f-3639-4031-8032-11d874ad7a57",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
            "Origin": "https://bi.aliyun.com",
            "x-requested-with": "XMLHttpRequest",
            "Accept": "*/*",
            "Accept-Encoding": "gzip, deflate, br, zstd",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Cache-Control": "no-cache"
        }
        self.default_params = {
            "componentId": "bd9850aa-d5c8-4cbf-bdd0-e0ecfd3c1acf",
            "reportId": "2be4810f-3639-4031-8032-11d874ad7a57",
            "componentType": "3"
        }
        # 初始化时获取cookie
        self.get_cookie()
    
    def get_cookie(self):
        """
        动态获取cookie
        """
        try:
            # 这里使用用户提供的access_key和secret来获取cookie
            # 注意：实际生产环境中，需要使用阿里云的认证服务来获取有效的cookie
            # 这里我们使用一个模拟的方式，实际使用时需要根据阿里云的认证流程进行修改
            
            # 1. 首先访问阿里云登录页面获取初始cookie
            login_url = "https://account.aliyun.com/login/login.htm"
            session = requests.Session()
            response = session.get(login_url, timeout=30)
            print(f"登录页面状态码: {response.status_code}")
            
            # 2. 从响应中获取cookie
            cookies = session.cookies.get_dict()
            if cookies:
                # 拼接cookie字符串
                self.cookie = '; '.join([f"{k}={v}" for k, v in cookies.items()])
                # 更新headers中的cookie
                self.headers["Cookie"] = self.cookie
                self.headers["x-csrf-token"] = self.csrf_token
                print(f"获取cookie成功: {self.cookie}")
            else:
                print("获取cookie失败，未返回cookie")               
        except Exception as e:
            print(f"获取cookie出错: {e}")
    
    def build_olap_query_param(self, start_month, end_month):
        """
        构建olapQueryParam参数
        """
        return {
            "componentId": "bd9850aa-d5c8-4cbf-bdd0-e0ecfd3c1acf",
            "componentName": "每天约课趋势图",
            "configs": [
                {
                    "type": "field",
                    "config": {
                        "fields": [
                            {
                                "guid": "ddaf6b72-cb73-492f-863f-ae5cea126e54",
                                "fid": "d202846266",
                                "areaType": "row",
                                "geographicInfoModel": 0,
                                "dateTrunc": "day"
                            },
                            {
                                "guid": "26ce72cf-cec2-40cd-b598-a1a21b6fee0b",
                                "fid": "5b791f71ee",
                                "areaType": "column",
                                "geographicInfoModel": 0,
                                "aggregate": "sum"
                            },
                            {
                                "guid": "64c5e522-69d0-486c-a284-ba097340f01f",
                                "fid": "146feeaf6a",
                                "areaType": "column",
                                "geographicInfoModel": 0,
                                "aggregate": "sum"
                            },
                            {
                                "guid": "a667067d-3152-4b75-b6f1-b8cc4e7a0985",
                                "fid": "634d6b7c6f",
                                "areaType": "column",
                                "geographicInfoModel": 0,
                                "aggregate": "sum"
                            },
                            {
                                "guid": "5dce386a-46df-43f4-95ef-8ba08c6bbda8",
                                "fid": "3a9addfc08",
                                "areaType": "column",
                                "geographicInfoModel": 0,
                                "aggregate": "sum"
                            },
                            {
                                "guid": "8070014d-f624-4c85-88da-adcfd25b6451",
                                "fid": "30387533ab",
                                "areaType": "column",
                                "geographicInfoModel": 0,
                                "aggregate": "sum"
                            }
                        ]
                    },
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342"
                },
                {
                    "type": "paging",
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342",
                    "config": {
                        "limit": 1000,
                        "offset": 0,
                        "pagedByAllDim": True
                    }
                },
                {
                    "type": "beforeAggregateCondition",
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342",
                    "config": {
                        "logicalOperator": "AND",
                        "conditions": [
                            {
                                "field": {
                                    "fid": "1f0c426538",
                                    "dateTrunc": "month"
                                },
                                "functionalOperator": "greaterThanOrEqual",
                                "args": [
                                    {
                                        "valueType": "string",
                                        "value": start_month
                                    }
                                ]
                            },
                            {
                                "field": {
                                    "fid": "1f0c426538",
                                    "dateTrunc": "month"
                                },
                                "functionalOperator": "lessThanOrEqual",
                                "args": [
                                    {
                                        "valueType": "string",
                                        "value": end_month
                                    }
                                ]
                            }
                        ]
                    }
                },
                {
                    "type": "sort",
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342",
                    "config": {
                        "sortFields": [
                            {
                                "sortType": "asc",
                                "guid": "ddaf6b72-cb73-492f-863f-ae5cea126e54",
                                "dimValues": [],
                                "groupSort": False
                            }
                        ]
                    }
                },
                {
                    "type": "queryConfig",
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342",
                    "config": {
                        "needCount": False,
                        "queryCount": False,
                        "queryDetail": False
                    }
                },
                {
                    "type": "advancedParam",
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342",
                    "config": {
                        "autoInsightParam": {
                            "enable": False
                        },
                        "wordCloudParam": {},
                        "summarizeParams": [],
                        "trendLineParams": [],
                        "forecastParams": [],
                        "anomalyDetectionParams": [],
                        "clusteringParams": [],
                        "groupParam": None,
                        "dynamicMetricParam": {}
                    }
                },
                {
                    "type": "annotationParam",
                    "cubeId": "5ec7bb4a-8838-4dbd-a0bf-947595171342",
                    "config": {
                        "measureThresholdParams": [],
                        "inflectionPointParams": []
                    }
                }
            ],
            "dataType": "general",
            "reportId": "2be4810f-3639-4031-8032-11d874ad7a57"
        }
    
    def query(self, start_month, end_month):
        """
        执行查询
        """
        try:
            # 构建请求参数
            olap_query_param = self.build_olap_query_param(start_month, end_month)
            
            data = {
                "olapQueryParam": json.dumps(olap_query_param),
                **self.default_params
            }
            
            # 发送请求
            response = requests.post(
                self.base_url,
                headers=self.headers,
                data=data,
                timeout=30
            )
            
            print(f"状态码: {response.status_code}")
            print(f"响应头: {dict(response.headers)}")
            print(f"响应内容: {response.text}")
            
            # 尝试解析JSON
            try:
                json_data = response.json()
                print(f"JSON解析成功: {json_data}")
                return json_data
            except json.JSONDecodeError:
                print("响应不是有效的JSON格式")
                return response.text
                
        except Exception as e:
            print(f"请求出错: {e}")
            return None

def main():
    # 公共参数
    access_key_id = "your_access_key_id"  # 需要替换为实际的AccessKey ID
    access_key_secret = "your_access_key_secret"  # 需要替换为实际的AccessKey Secret
    aliyun_id = "your_aliyun_id"  # 需要替换为实际的阿里云账号ID
    csrf_token = "your_csrf_token"
    
    # 创建客户端实例
    # client = BiApiClient(access_key_id, access_key_secret, aliyun_id, csrf_token)
    client = BiApiClient(access_key_id, access_key_secret, csrf_token)
    
    # 执行查询（2026年2月到2026年4月）
    result = client.query("202602", "202604")
    
    return result

if __name__ == "__main__":
    main()