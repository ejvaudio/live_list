class API::V1::ListItemsController < ApplicationController

  # GET /list_items
  def index
    @list_items = ListItem.all
    render json: @list_items
  end

  # POST /lists/:list_id
  def create
    @list = List.find(params[:list_id])
    #@list.list_items_attributes = [ { title: "Title here", index: 0, order: 1, list_type: "item" } ]
    #@list.list_items_attributes = [ list_item_params ]
    @list_item = @list.list_items.build(list_item_params)

    if @list.save

      #firehose pub
      #rely on AMS to create our JSON response properly. Since we need AMS outside of the render: json call we use the Serializer call directly
      json = ListItemSerializer.new(@list_item).to_json
      json = JSON.parse(json)
      #can't figure out how to get AMS to remove the root (i.e. root: false) when calling the Serializer method directly. Brute force remove the root here
      json = json["list_item"]
      #add our customer attributes that are only used by the Firehose clients
      json["action"] = "add"
      json["cid"] = params[:cid]
      json = json.to_json
      firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
      firehose.publish(json).to("/live_list")

      render json: json, status: :created
    else
      render json: @list.errors, status: :unprocessable_entity
    end
  end

  # PATCH /list/:list_id/:list_item_id
  def update

    @list = List.find(params[:list_id])
    p = list_item_params

    # hack to not update the "selected" attribute in the DB, just communicate it to the clients
    if(params[:selected])
      message = {cid: params[:cid], action: "select", id: params[:list_item_id]}
      json = message.to_json
      firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
      firehose.publish(json).to("/live_list")
    else
      p[:id] = params[:list_item_id]
      @list.list_items_attributes = [p]
      
      if @list.save
        p[:cid] = params[:cid]
        p[:action] = "update"
        json = p.to_json
        firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
        firehose.publish(json).to("/live_list")



        render json: p, status: :created
      else
        render json: {response: "error"}, status: :unprocessable_entity
      end
    end


  end

  # DELETE /list/:list_id/:list_item_id
  def delete

    @list = List.find(params[:list_id])
    p = list_item_params
    p[:id] = params[:list_item_id]
    p[:_destroy] = 1

    @list.list_items_attributes = [ p ]

    if @list.save
      p[:cid] = params[:cid]
      p[:action] = "delete"
      json = p.to_json
      firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
      firehose.publish(json).to("/live_list")

      head :no_content
    else
      render json: {response: "error"}, status: :unprocessable_entity
    end
  end

  private

    def list_item_params
      params.permit(:index, :order, :title, :list_type, :id)
    end


end
