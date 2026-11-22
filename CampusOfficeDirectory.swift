import Foundation

enum CampusOfficeCategory: String, CaseIterable, Identifiable {
    case finance = "财务"
    case administration = "行政"
    case purchasing = "采购与资产"
    case campusServices = "校园服务"

    var id: Self { self }

    var icon: String {
        switch self {
        case .finance: return "creditcard"
        case .administration: return "building.2"
        case .purchasing: return "shippingbox"
        case .campusServices: return "person.crop.rectangle"
        }
    }
}

struct CampusOfficeLink: Identifiable {
    let title: String
    let url: URL

    var id: String { title }

    init(_ title: String, _ address: String) {
        self.title = title
        self.url = URL(string: address)!
    }
}

struct CampusOfficeContact: Identifiable {
    let name: String
    let location: String?
    let phone: String?
    let directory: CampusOfficeLink?

    var id: String { name + (location ?? "") }

    init(_ name: String, _ location: String? = nil, _ phone: String? = nil, directory: CampusOfficeLink? = nil) {
        self.name = name
        self.location = location
        self.phone = phone
        self.directory = directory
    }
}

struct CampusOfficeService: Identifiable {
    let id: String
    let category: CampusOfficeCategory
    let title: String
    let subtitle: String
    let keywords: String
    let entry: CampusOfficeLink
    let directions: String
    let materials: [String]
    let contacts: [CampusOfficeContact]
    let references: [CampusOfficeLink]
    var steps: [String] = []
    var relatedIDs: [String] = []

    func matches(_ words: [Substring], includingMaterials: Bool = true) -> Bool {
        let contactTerms = contacts.flatMap { [$0.name, $0.location ?? "", $0.phone ?? ""] }
        let index = ([title, subtitle, category.rawValue, keywords, entry.title] + contactTerms + (includingMaterials ? materials : []))
            .joined(separator: " ")
        return words.allSatisfy { index.localizedStandardContains(String($0)) }
    }
}

enum CampusOfficeDirectory {
    private static let financeContacts = CampusOfficeLink("财务处联系方式", "https://www.cwc.ynu.edu.cn/jgsz/kszz.htm")
    private static let officeContacts = CampusOfficeLink("党政办联系方式", "https://office.ynu.edu.cn/bmjs/lxwm.htm")
    private static let purchasingContacts = CampusOfficeLink("招采中心公开联系方式", "https://www.zczx.ynu.edu.cn/info/1015/1533.htm")
    private static let itContact = CampusOfficeContact("信息技术中心 · 运维服务", "呈贡 · 敬宾楼 3 楼", "0871-65031141",
                                                       directory: .init("信息技术中心联系方式", "https://www.itc.ynu.edu.cn/lxwm.htm"))
    private static let accounting = [
        CampusOfficeContact("财务处 · 会计核算中心", "呈贡 · 明远楼 142 室", "0871-65939035", directory: financeContacts),
        CampusOfficeContact("财务处 · 会计核算中心", "东陆 · 文津楼二楼师生综合服务大厅", "0871-65033883", directory: financeContacts)
    ]
    private static let unitOffice = CampusOfficeContact("所在学院或部门办公室")
    private static let seals = CampusOfficeContact("党政办公室 · 综合科", "呈贡 · 明远楼 430 室", "0871-65033906", directory: officeContacts)
    private static let legal = CampusOfficeContact("党政办公室 · 法律事务办公室", "呈贡 · 明远楼 428 室", "0871-65032159", directory: officeContacts)
    private static let purchasing = CampusOfficeContact("招标与采购管理中心", "呈贡 · 明远楼 146 室", "0871-65010906", directory: purchasingContacts)
    private static let unitAssets = CampusOfficeContact("所在学院或部门 · 资产管理员")
    private static let assetContacts = CampusOfficeLink("资产与实验室管理处科室电话", "https://www.zsc.ynu.edu.cn/jgsz.htm")
    private static let equipment = CampusOfficeContact("资产与实验室管理处 · 仪器设备管理科", nil, "0871-65033879", directory: assetContacts)
    private static let travelPolicy = CampusOfficeLink("国内差旅费管理办法（修订）",
        "https://www.cwc.ynu.edu.cn/__local/9/FF/FF/6CE9F153B02E0FB1DAE4D726B0E_6E30BB6D_7A966.pdf")
    private static let sealPolicy = CampusOfficeLink("行政印章管理办法及附件",
        "https://office.ynu.edu.cn/fwzn/yxbl/yndxxzyzgl.htm")
    private static let financePortal = CampusOfficeLink("打开综合财务信息平台", "https://fm-cwc.ynu.edu.cn/Api/CAS/Login")
    private static let campusPortal = CampusOfficeLink("打开融合门户", "https://casp.ynu.edu.cn/")
    private static let financeRemote = CampusOfficeLink("财务系统校外访问说明", "https://www.itc.ynu.edu.cn/info/1004/1703.htm")
    private static let purchaseRules = CampusOfficeLink("非政府采购实施细则", "https://www.zczx.ynu.edu.cn/info/1003/1541.htm")
    private static let procurementPortal = CampusOfficeLink("打开资产与实验室管理处", "https://www.sysysb.ynu.edu.cn/")
    private static let assetPortal = CampusOfficeLink("打开国有资产管理系统", "https://zcgl-sysysb.ynu.edu.cn/")
    private static let assetGuide = CampusOfficeLink("仪器设备验收入账指南", "https://www.zsc.ynu.edu.cn/info/1054/1654.htm")
    private static let assetPolicy = CampusOfficeLink("学校固定资产管理办法", "https://office.ynu.edu.cn/info/1107/1550.htm")
    private static let invoiceGuide = CampusOfficeLink("财务处报销发票要求", "https://www.cwc.ynu.edu.cn/info/1047/1238.htm")
    private static let spendingPolicy = CampusOfficeLink("经费管理及审批办法", "https://www.cwc.ynu.edu.cn/info/1042/1397.htm")
    private static let spendingGuide = CampusOfficeLink("财务处经费使用指南", "https://www.cwc.ynu.edu.cn/__local/A/EC/E9/047F998E680AD609FA5726CB452_B5DDD11D_25FB3D.pdf?e=.pdf")
    private static let contractForm = CampusOfficeLink("查看一般合同签署申请表", "https://www.flsw.ynu.edu.cn/info/1007/1202.htm")
    private static let cooperationNotice = CampusOfficeLink("2026 年产学合作协同育人申报通知", "https://jwc.ynu.edu.cn/info/1009/4345.htm")
    private static let sealForm = CampusOfficeLink("打开行政用印表单", "https://office.ynu.edu.cn/info/1032/1073.htm")

    static let services: [CampusOfficeService] = [
        .init(id: "ordinary-claim", category: .finance, title: "日常办公费报销", subtitle: "办公用品、打印复印等日常支出",
              keywords: "普通报销 日常报销 网报 报账 采购报销 办公用品 办公耗材 印刷 打印复印 发票",
              entry: financePortal,
              directions: "先确认经费允许列支、采购和资产手续已办齐。涉及低值易耗品登记、资产报增或合同付款时，从下方跳到对应事项。",
              materials: [
                "报账经费项目号、用途、金额及网报单",
                "抬头为「云南大学」的合规发票。电子发票保留原文件，并在网报系统录入票据信息",
                "商品或服务明细。购置实物按财务处要求由经办人与验收人分别签字",
                "公务卡支付的，留刷卡凭条或交易记录。公对公付款时核对合同、发票与收款方",
                "按实际采购类型附审批、合同或登记凭证"
              ],
              contacts: accounting, references: [invoiceGuide, spendingPolicy, financeRemote],
              steps: ["选项目号，核对经费用途及审批要求", "在财务平台填写报销并选择支付方式", "按系统和财务窗口要求提交审批及附件"],
              relatedIDs: ["low-value-registration", "fixed-asset-claim", "service-payment", "invoice-prep"]),
        .init(id: "travel-claim", category: .finance, title: "国内差旅报销", subtitle: "出差回来后提交票据",
              keywords: "出差报销 报账 差旅费 交通费 酒店 机票 发票 科研经费",
              entry: financePortal,
              directions: "出差结束后在财务平台填报差旅。票据、日期、行程要能与审批记录对应。校外访问按学校指引使用 WebVPN。",
              materials: [
                "已审批的出差审批单、差旅费报销单",
                "实际发生的城市间交通票据。乘飞机时按规定附购票时点票价对比等材料",
                "住宿发票及适用的公务卡刷卡凭条",
                "有会议费、会务费或经批准的退改签费用时，附参会通知和有关票据"
              ],
              contacts: accounting,
              references: [travelPolicy, .init("铁路与航空电子发票报销", "https://www.cwc.ynu.edu.cn/info/1047/1231.htm"), financeRemote],
              steps: ["整理审批单、实际行程及票据，逐项核对日期", "在财务平台填差旅单并录入电子票据信息", "机票、住宿或退改签等有特殊情况时，按差旅办法补齐对应说明和证明"],
              relatedIDs: ["travel-approval", "invoice-prep"]),
        .init(id: "fixed-asset-claim", category: .finance, title: "固定资产报销", subtitle: "报增完成后网报",
              keywords: "固定资产报账 设备发票 买电脑报销 报增后报销 入账付款",
              entry: financePortal,
              directions: "适用于已经完成资产登记的设备等。报增单由资产环节产生，报销单在财务平台填写。",
              materials: ["固定资产报增单（或系统出具的资产增加凭证）",
                          "采购结果登记表或政府采购合同，按实际采购方式备齐",
                          "发票及网报单，核对设备名称、规格、数量及金额",
                          "按合同或采购要求应随款项提交的验收、结算等资料"],
              contacts: accounting, references: [spendingGuide, invoiceGuide],
              steps: ["向单位资产管理员取已审核的报增凭证", "选对应经费项目，填写固定资产报销", "附资产、采购和发票资料，按财务要求送审"],
              relatedIDs: ["equipment-registration", "purchase-contract"]),
        .init(id: "service-payment", category: .finance, title: "合同款支付与报销", subtitle: "按履约和付款节点办款",
              keywords: "合同报销 服务费报销 合同付款 公对公 转账 预付款 尾款 分期 结算",
              entry: financePortal,
              directions: "按已签合同核对付款对象、节点和相应的验收条件。预付款、分期和尾款所需附件按合同和财务审批要求确认。",
              materials: ["已签署的合同及适用的付款条款、补充协议",
                          "本期应付金额、收款单位和账户资料",
                          "按付款节点需提交的发票、验收报告或交付证明",
                          "已付记录或上期付款凭证（适用时），以及本次经费项目和网报单"],
              contacts: accounting, references: [spendingPolicy, invoiceGuide],
              steps: ["核对合同本期付款条件、开票方和收款方", "按节点整理履约材料，在财务系统填报并审批"],
              relatedIDs: ["general-contract", "purchase-contract", "service-acceptance", "fixed-asset-claim"]),
        .init(id: "invoice-prep", category: .finance, title: "电子发票与报销投单", subtitle: "开票信息、录入和提交前检查",
              keywords: "数电票 电子票据 发票抬头 税号 纳税人识别号 发票查重 铁路电子客票 自助投单 报销确认单",
              entry: financePortal,
              directions: "开票前在财务处指南核抬头和税号。已经获得电子票据时，留存原件，按系统要求录入，并确认这张票未用于其他报销单。",
              materials: ["电子发票原文件及财务要求的附件",
                          "发票号码、开票日期及金额",
                          "网报单、审批材料及本事项要求的合同、明细或支付凭据"],
              contacts: accounting,
              references: [invoiceGuide,
                           .init("火车与飞机电子发票指南", "https://www.cwc.ynu.edu.cn/info/1047/1231.htm"),
                           .init("自助投单操作说明", "https://www.cwc.ynu.edu.cn/__local/F/67/5F/5BDC84FB451CA3BEA61B3837B46_E6C76D46_18F1DC.pdf")],
              steps: ["核对票面名称、税号、内容、金额和销售方", "在对应网报单录入电子发票，实物验收和支付凭据随单准备", "按当前系统提示办理线上提交或线下投单"],
              relatedIDs: ["ordinary-claim", "travel-claim"]),
        .init(id: "travel-approval", category: .finance, title: "教职工出差审批", subtitle: "行前填表和审批",
              keywords: "因公外出 出差报备 外出请假 差旅 出差审批单",
              entry: .init("打开学校 OA", "https://new-oa.ynu.edu.cn/seeyon/index.jsp"),
              directions: "行前请所在单位确认适用的外出审批流程。留存审批完成的表单，报销时一并提交。",
              materials: [
                "与身份相符的外出审批表",
                "外出事由、往返日期、目的地和经费来源",
                "会议通知或邀请函（适用时）"
              ],
              contacts: [unitOffice],
              references: [.init("外出审批表下载", "https://www.cwc.ynu.edu.cn/cyxz.htm"), travelPolicy]),
        .init(id: "card", category: .finance, title: "公务卡办理", subtitle: "查办卡方式与出纳科",
              keywords: "公务卡 银行卡 还款 支付 办卡",
              entry: .init("查看公务卡办卡须知", "https://www.cwc.ynu.edu.cn/info/1043/1371.htm"),
              directions: "按财务处的办卡须知确认办理方式、受理网点和所需证件。支付、还款或变更问题可先咨询出纳科。",
              materials: ["按办卡须知准备证件和申请资料", "已有公务卡的，咨询时说明是支付、还款还是卡信息变更"],
              contacts: [.init("财务处 · 出纳科", "呈贡 · 明远楼 237 室", "0871-65036619", directory: financeContacts)],
              references: []),
        .init(id: "accounting-record", category: .finance, title: "财务凭证查阅", subtitle: "调阅或复印历史报账凭证",
              keywords: "会计档案 查账 凭单 报销记录 审计 复印",
              entry: .init("查看查阅流程及申请表", "https://www.cwc.ynu.edu.cn/__local/A/EC/E9/047F998E680AD609FA5726CB452_B5DDD11D_25FB3D.pdf?e=.pdf"),
              directions: "按《经费使用指南》的档案查询部分准备申请表，先联系稽核科确认凭证保管地点和办理方式。",
              materials: ["财务档案查询申请表，注明项目号、凭证号、查询理由和复印需求",
                          "查询人姓名、工号或学号及联系方式",
                          "申请表按指南要求签字盖章"],
              contacts: [.init("财务处 · 稽核科", "呈贡 · 明远楼 239 室", "0871-65918081", directory: financeContacts)],
              references: []),
        .init(id: "seal", category: .administration, title: "学校行政用印", subtitle: "申请学校行政校印",
              keywords: "公章 盖章 校印 签名章 办公室 印信",
              entry: sealForm,
              directions: "由申请单位签署意见。按事项要求取得对口部门审批后，联系党政办公室办理。以学校名义签订合同或协议时，走合同签批流程。",
              materials: ["行政印章使用申请表", "需要加盖印章的定稿材料", "申请单位和对口业务部门的审批意见（按事项要求）"],
              contacts: [seals], references: [sealPolicy], relatedIDs: ["project-seal", "general-contract"]),
        .init(id: "project-seal", category: .administration, title: "项目申报书用印", subtitle: "先判断要盖学院章、业务章还是校章",
              keywords: "项目申请用印 项目申请 申报盖章 科研项目 教改 基金 申报书 申请书 承诺书 推荐意见 学校公章",
              entry: sealForm,
              directions: "按本次项目通知确定印章及归口部门。自然科学、哲社和教学项目分别从主管部门或学院科研秘书、教务经办人确认。学校行政用印一事一报。",
              materials: ["本次申报通知及载明印章、签字、提交方式的要求",
                          "拟提交的完整申请书、签字盖章页及通知要求的附件",
                          "学院审核或推荐意见，以及对口部门审核意见（按项目通知）",
                          "明确要盖学校行政章的，填写行政印章使用申请表"],
              contacts: [
                .init("所在学院 · 科研秘书或教务经办人"),
                .init("科学技术处 · 自然科学项目", directory: .init("科学技术处", "https://www.sto.ynu.edu.cn/")),
                .init("社会科学处 · 哲社项目", directory: .init("社会科学处", "https://www.hsd.ynu.edu.cn/")),
                seals
              ],
              references: [sealPolicy, cooperationNotice],
              steps: ["查当次通知，确认盖章主体、送审顺序和校内截止时间",
                      "由学院和对应归口部门审核。需校章时，持签批表和定稿联系党政办",
                      "扫描盖章后的完整申报材料，按通知提交。后续签订合作协议时办理合同签批"],
              relatedIDs: ["cooperation-project", "general-contract", "seal"]),
        .init(id: "cooperation-project", category: .administration, title: "产学合作项目申报与用印", subtitle: "2026 年协同育人项目办理示例",
              keywords: "产学合作 协同育人 教学项目 企业协议 校企协议 申报用印 项目申请用印",
              entry: .init("打开产学合作项目平台", "https://cxhz.hep.com.cn/"),
              directions: "按本科生院 2026 年通知办理。先提交经校级教学主管部门审核签章的申报书，审核通过后再签校企合作协议。",
              materials: ["按拟申报企业项目下载并填写的申报书",
                          "填好校方审核意见的纸质申报书。企业明确要求学校行政章时，附行政用印申请表",
                          "审核通过后准备校企合作协议、一般合同签署申请表。该通知要求协议至少四份原件"],
              contacts: [.init("本科生院 · 实践教学科", nil, "0871-65031440", directory: cooperationNotice), legal],
              references: [sealForm, contractForm],
              steps: ["项目平台选项目并下载模板，送本科生院或研究生院审核、签字和盖章",
                      "上传盖章扫描件，联系企业和学校项目管理员审核",
                      "拟定协议并经法务审批盖合同专用章，上传平台供双方确认"],
              relatedIDs: ["project-seal", "general-contract"]),
        .init(id: "general-contract", category: .administration, title: "一般合同签订与盖章", subtitle: "合作协议、教材出版等一般合同",
              keywords: "合同签订 签约 合同审批 合同用印 法务审核 法务审查 合同专用章 合作协议",
              entry: contractForm,
              directions: "签署前由经办单位确认归口部门及适用表单，持拟签文本按流程送审。涉及采购的，从「采购合同签订」进入。",
              materials: ["拟签合同或协议定稿、附件与相关项目依据",
                          "学校合同签署申请表，按事项补齐归口部门和法律事务办公室的审核",
                          "对方主体及签署人信息，合同涉及授权时准备相应材料",
                          "确认签署原件、对方留存和校内归档份数，按具体事项要求准备"],
              contacts: [unitOffice, legal], references: [sealPolicy, cooperationNotice],
              steps: ["确认是一般合同还是采购合同，核实对方和履约、付款条款",
                      "按学校要求提交合同签批，获批后办理签署及合同用印",
                      "留存签署版和附件。后续付款按约定节点准备报账材料"],
              relatedIDs: ["purchase-contract", "service-payment", "project-seal"]),
        .init(id: "intro-letter", category: .administration, title: "学校介绍信申请", subtitle: "单位起草后申请出具",
              keywords: "介绍信 对外联系 用印 盖章",
              entry: .init("查看介绍信申请表（附件 3）", "https://office.ynu.edu.cn/fwzn/yxbl/yndxxzyzgl.htm"),
              directions: "由申请单位撰写介绍信并签署意见。需要对口业务部门审批时，签署后再办理。",
              materials: ["介绍信申请表", "介绍信正文，写清人员姓名、人数、目的地和联系事项", "申请单位和对口业务部门的审批意见（按事项要求）"],
              contacts: [seals], references: []),
        .init(id: "legal-certificate", category: .administration, title: "法人证件使用", subtitle: "申请使用法人证或法人身份证",
              keywords: "法人证 法定代表人 身份证 法人证明 资质 证照",
              entry: .init("查看法人证件使用表（附件 2）", "https://office.ynu.edu.cn/fwzn/yxbl/yndxxzyzgl.htm"),
              directions: "由申请单位发起。法定代表人委托、CA 数字证书使用在同页有各自的表单和审批要求。",
              materials: ["法人证、法人身份证使用申请表", "用途和办理事项", "申请单位和对口业务部门的审批意见（按事项要求）"],
              contacts: [seals], references: []),
        .init(id: "business-visitor", category: .administration, title: "因公来访预约", subtitle: "校外访客入校与接待",
              keywords: "访客 入校 校门 门禁 对外接待 专家 来访 平安云大",
              entry: .init("查看学校入校预约入口说明", "https://www.ynu.edu.cn/info/1153/35147.htm"),
              directions: "访客通过微信关注「平安云大」，选择对应校区的访客入口。因公来访请先与校内接待人确认预约及审核信息。",
              materials: ["来访人的姓名、手机号码和有效证件", "来访单位、校区、计划到访时段及校内接待人", "驾车或多人同行时，按预约页面填写车牌和同行信息"],
              contacts: [.init("校内接待人 · 确认预约及审核"), .init("公安处 · 校门通行咨询", nil, "0871-65039110",
                  directory: .init("学校电话查询", "https://www.hqjt.ynu.edu.cn/info/1046/1034.htm"))],
              references: []),
        .init(id: "purchase-request", category: .purchasing, title: "采购项目申报", subtitle: "买设备、办公用品或服务前",
              keywords: "采购申请 资产采购 买设备 办公用品 买电脑 预算 申购",
              entry: procurementPortal,
              directions: "在资产与实验室管理处网站选择「资产采购」，进入项目申报。先请经费负责人或经办人确认经费和适用采购方式，再提交审批。",
              materials: ["采购内容、用途、数量、规格或服务要求", "预算及拟使用的经费项目", "如项目涉及进口设备等专项论证，先根据学校要求准备相关材料"],
              contacts: [purchasing],
              references: [.init("采购申报操作指南", "https://www.zczx.ynu.edu.cn/info/1006/1459.htm"),
                           .init("学校招标与采购管理办法", "https://www.zczx.ynu.edu.cn/info/1003/1540.htm"),
                           .init("大型仪器设备论证报告（2026 版）", "https://www.sysysb.ynu.edu.cn/info/1064/1635.htm")],
              relatedIDs: ["purchase-contract", "low-value-registration", "equipment-registration"]),
        .init(id: "low-value-registration", category: .purchasing, title: "低值易耗品登记与报销", subtitle: "到货后登记，留齐财务附件",
              keywords: "低值易耗品报销 办公耗材 实验耗材 低值品 低值易耗品台账 验货 入库 领用",
              entry: .init("打开低值易耗品登记平台", "https://www.hc-zsc.ynu.edu.cn/"),
              directions: "先请本单位资产管理员核对品类、经费要求与是否需要登记。需要登记的，在学校低值易耗品平台按经办人手册操作，网报时保留对应登记资料。",
              materials: ["采购订单、购物明细或送货单，能对应到物品名称、规格和数量",
                          "到货验收记录及实际经办、验收人员信息",
                          "合规发票、支付凭据和经费项目号",
                          "适用的登记凭证、台账或审批资料。提交格式按平台和财务窗口要求"],
              contacts: [unitAssets, .init("资产与实验室管理处 · 综合业务科", nil, "0871-65933083", directory: assetContacts)] + accounting,
              references: [.init("低值易耗品平台经办人手册", "https://www.zczx.ynu.edu.cn/info/1006/1523.htm"), spendingGuide, invoiceGuide],
              steps: ["确认品类和校内采购方式，到货后核验数量与明细",
                      "按手册在学校平台登记，留存登记凭证和与发票对应的购物清单",
                      "在综合财务信息平台提交网报单，附发票、明细和适用的登记凭证"],
              relatedIDs: ["ordinary-claim", "equipment-registration", "invoice-prep"]),
        .init(id: "equipment-registration", category: .purchasing, title: "固定资产验收与报增", subtitle: "设备到货后找资产管理员办理",
              keywords: "固定资产 资产报增 设备验收入账 设备建账 资产标签 电脑 家具 国有资产",
              entry: assetPortal,
              directions: "先与本单位资产管理员确认是否纳入固定资产、资产归属和验收方式。按采购及合同要求完成验收后，再在国有资产管理系统办理报增。",
              materials: ["采购合同或采购文件、采购结果和发票",
                          "设备及到货明细，核对名称、规格型号、数量",
                          "验收单据，按国产、进口等适用情形选择学校表单",
                          "使用单位、存放地点、领用或保管人员等资产登记信息"],
              contacts: [unitAssets, equipment],
              references: [assetGuide, .init("仪器设备验收表单下载", "https://www.sysysb.ynu.edu.cn/xzzx.htm"), assetPolicy],
              steps: ["按采购文件与合同清点、验收设备", "联系本单位资产管理员录入报增并提交审核",
                      "取得报增凭证，再准备固定资产报销"],
              relatedIDs: ["fixed-asset-claim", "low-value-registration", "purchase-contract"]),
        .init(id: "purchase-contract", category: .purchasing, title: "采购合同签订", subtitle: "按政府采购或校内自行采购选模板",
              keywords: "采购合同签订 政府采购合同 校内自行采购合同 询价合同 合同盖章 法务 中标 成交",
              entry: .init("打开政府采购合同办理指南", "https://www.zczx.ynu.edu.cn/info/1006/1458.htm"),
              directions: "先按已批准的采购方式向招采中心确认签订流程。政府采购有设备、服务和工程等模板。校内自行询价有货物、服务两类合同模板。",
              materials: ["采购审批和适用的成交、中标或询价材料",
                          "与采购方式、货物或服务类别对应的合同文本及附件",
                          "供应商信息、签署与授权资料，并核对标的、数量、价款、交付、验收和付款条款",
                          "按学校流程所需的签批资料及留档原件"],
              contacts: [purchasing, legal],
              references: [.init("采购合同管理细则（试行）", "https://www.zczx.ynu.edu.cn/info/1003/1538.htm"),
                           .init("政府采购合同模板", "https://www.zczx.ynu.edu.cn/info/1005/1503.htm"),
                           .init("校内自行询价合同模板", "https://www.zczx.ynu.edu.cn/info/1005/1474.htm")],
              steps: ["核对采购结果和适用合同模板", "按采购类型提交合同审核及签订，保留签署版",
                      "按适用流程备案，验收后凭合同等材料办理付款"],
              relatedIDs: ["purchase-filing", "equipment-registration", "service-acceptance", "service-payment"]),
        .init(id: "purchase-filing", category: .purchasing, title: "自行询价采购备案", subtitle: "已按校内自行询价方式采购",
              keywords: "采购结果备案 询价 比价 三家 供应商 非政府采购 合同模板",
              entry: procurementPortal,
              directions: "进入「资产采购 → 采购执行 → 采购结果备案登记（校采）」。使用原申报账号，按系统要求上传材料。",
              materials: ["与货物或服务类别对应的、已签字盖章的合同 PDF", "三家供应商加盖公章的报价单", "校内自行询价采购询价报告"],
              contacts: [purchasing],
              references: [.init("询价报告、合同模板及备案指南", "https://www.zczx.ynu.edu.cn/info/1005/1474.htm"), purchaseRules],
              relatedIDs: ["purchase-contract", "equipment-registration", "service-payment"]),
        .init(id: "service-acceptance", category: .purchasing, title: "服务类采购验收", subtitle: "组织履约检查并留档",
              keywords: "验收报告 验收模板 履约 结项 服务合同 归档",
              entry: .init("打开验收指南及报告模板", "https://www.zczx.ynu.edu.cn/info/1006/1545.htm"),
              directions: "此指南适用于合同金额 20 万元及以上的服务类项目。由采购单位组织验收，以合同约定的期限和要求为准。",
              materials: ["采购文件及合同", "能核对服务进度、质量和交付结果的履约资料", "验收报告，由验收小组签字、采购单位盖章"],
              contacts: [.init("本项目采购单位 · 组织验收"), purchasing], references: [],
              relatedIDs: ["purchase-contract", "service-payment"]),
        .init(id: "fixed-ip", category: .campusServices, title: "办公设备固定 IP", subtitle: "打印机、服务器等设备接入校园网",
              keywords: "固定IP 固定 IP 地址 打印机 服务器 MAC 办公室 网络",
              entry: campusPortal,
              directions: "登录后搜索「固定IP地址申请」。审核生效后，设备通过自动获取 IP（DHCP）领取绑定地址。",
              materials: ["设备用途和设备类型", "设备网卡的 MAC 地址", "部署地点"],
              contacts: [itContact],
              references: [.init("固定 IP 申请指南", "https://itc.ynu.edu.cn/fwdh/wlfw/gdIPsq.htm")]),
        .init(id: "network", category: .campusServices, title: "校园网账号服务", subtitle: "校园网上网与账号找回",
              keywords: "Wi-Fi 无线 网络密码 VPN 密码 宽带",
              entry: .init("打开校园网自助服务", "http://202.203.208.5/"),
              directions: "已绑定手机时可通过校内自助服务找回。也可在云南大学企业微信工作台办理校园网（VPN）密码重置。",
              materials: ["学号或工号", "自助找回时，准备账号已绑定的手机接收验证码"],
              contacts: [itContact],
              references: [.init("上网账号开通与找回", "https://itc.ynu.edu.cn/fwdh/wlfw/swzhfw.htm")]),
        .init(id: "faculty-mail", category: .campusServices, title: "教职工邮箱绑定", subtitle: "绑定统一身份认证或配置客户端",
              keywords: "校园邮箱 云大邮箱 邮件 统一身份 绑定",
              entry: .init("打开云大邮箱", "https://webmail.ynu.edu.cn/"),
              directions: "先按学校指南从邮箱端生成客户端专用密码，再到统一身份认证绑定邮箱。配置手机邮件客户端可查学校邮件服务页。",
              materials: ["完整的教职工邮箱地址（@ynu.edu.cn）", "统一身份认证账号", "在邮箱设置中生成的客户端专用密码"],
              contacts: [itContact],
              references: [.init("邮箱绑定指南", "https://www.itc.ynu.edu.cn/info/1013/1686.htm"),
                           .init("教职工邮件服务", "https://itc.ynu.edu.cn/fwdh/xxhfw/yjfw.htm")]),
        .init(id: "campus-card", category: .campusServices, title: "校园卡挂失与补办", subtitle: "手机挂失、两校区窗口补办",
              keywords: "一卡通 卡务 遗失 补卡 挂失 解挂 卡密码",
              entry: .init("查看云大一卡通操作入口", "https://www.itc.ynu.edu.cn/info/1013/1687.htm"),
              directions: "在微信里搜索「云大一卡通」，进入卡务管理办理挂失。实体卡补办、解挂或密码重置可联系卡务服务点。",
              materials: ["首次绑定虚拟卡时准备姓名、学工号及校园卡支付密码", "补办实体卡前，向卡务点确认所需证件"],
              contacts: [
                .init("信息技术中心 · 一卡通服务部", "呈贡 · 中山邦翰楼就业服务大厅", "0871-65033382"),
                .init("东陆卡务点", "文渊楼一楼机房管理办公室")
              ],
              references: [])
    ]
}
