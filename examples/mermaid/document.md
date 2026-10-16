# Order model

The diagram is editable without losing the surrounding Markdown.

```mermaid
---
title: Order ownership
---
erDiagram
    accTitle: Customers and their orders
    accDescr: An account may own any number of orders.
    subgraph Accounts[Account records]
        CUSTOMER {
            int id PK
            string name
        }
    end
    subgraph Sales[Sales records]
        ORDER {
            int id PK
            int customer_id FK
        }
    end
    CUSTOMER only one to zero or more ORDER : places
```

This prose survives read/write and source edits unchanged.
