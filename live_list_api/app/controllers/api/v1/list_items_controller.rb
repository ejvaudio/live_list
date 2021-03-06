class API::V1::ListItemsController < ApplicationController

  # GET /list_items
  def index
    @list_items = ListItem.all
    render json: @list_items
  end

  # POST /lists/:list_id
  def create
    @list = List.find(params[:list_id])
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
      #configure the Firehose Producer
      firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
      #fire the pub to the specific list using the list_id. The JS clients will only sub to this specific list_id (i.e. channel)
      firehose.publish(json).to("/live_list/"+params[:list_id])

      render json: json, status: :created
    else
      render json: @list.errors, status: :unprocessable_entity
    end
  end

  # PATCH /lists/:list_id/:list_item_id
  def update

    @list = List.find(params[:list_id])
    p = list_item_params
    action_id = SecureRandom.uuid

    # hack to not update the "selected" attribute in the DB, just communicate it to the clients
    if(params[:selected])
      message = {cid: params[:cid], action: "select", id: params[:list_item_id]}
      json = message.to_json
      firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
      firehose.publish(json).to("/live_list/"+params[:list_id])
    else
      p[:id] = params[:list_item_id]
      #random uuid for this particular action. This is used because Firehose will send the most recent message when you reload the page and if we include the ID upon page reload we don't reapply an update that has already been applied. 
      p[:action_id] = action_id
      @list.list_items_attributes = [p]
      
      if @list.save
        p[:cid] = params[:cid]
        p[:action] = "update"
        json = p.to_json
        firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
        firehose.publish(json).to("/live_list/"+params[:list_id])

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
      firehose.publish(json).to("/live_list/"+params[:list_id])

      head :no_content
    else
      render json: {response: "error"}, status: :unprocessable_entity
    end
  end

  # PATCH /lists/:list_id/:list_item_id/control
  def update_control
    @list = List.find(params[:list_id])

    #action_id = SecureRandom.uuid
    action = Hash.new
    updated_items = []

    #if(@list.active_list_item != params[:list_item_id])
      if(!@list.active_list_item.blank?)
        @prev_item = @list.list_items.where(id: @list.active_list_item).first
        #render json: @prev_item and return
      else #previously active item is blank meaning this list was just created. So assign the index 1 as previousl active.
        #this line find the lowest index in the list. Since there should always be an index 1 we don't need this now
        #@prev_item = @list.list_items.min(:index)
        #instead just assume that index one is the "previous active"
        @prev_item = @list.list_items.where(index: 1).first

      end
    #end

    @active_item = @list.list_items.where(id: params[:list_item_id]).first
    @active_item.state = params[:state]

    #set the high level active list item
    @list.update_attributes(active_list_item: params[:list_item_id])

    updated_items.push({id: @active_item.id, state: params[:state]})

    if(@prev_item.index < @active_item.index)
      state = "post_active"
      #find items between prev_active and newly active
      @in_between_items = @list.list_items.gte(index: @prev_item.index).lt(index: @active_item.index)
    elsif(@prev_item.index > @active_item.index)
      state = "pre_active"
      #find items between prev_active and newly active
      @in_between_items = @list.list_items.lte(index: @prev_item.index).gt(index: @active_item.index)
    end

    if(!@in_between_items.blank?)
      render json: @in_between_items and return
      @in_between_items.each do |item|
        updated_items << {id: item.id, state: state}
      end

      #random uuid for this particular action. This is used because Firehose will send the most recent message when you reload the page and if we include the ID upon page reload we don't reapply an update that has already been applied. 
      #p[:action_id] = action_id
      @list.list_items_attributes = updated_items
    end
    
    if @list.save
      action[:cid] = params[:cid]
      action[:action] = "update_control"
      action[:updated_items] = updated_items
      json = action.to_json
      firehose = Firehose::Client::Producer::Http.new('//127.0.0.1:7474')
      firehose.publish(json).to("/live_list/"+params[:list_id])

      render json: action, status: :created
    else
      render json: {response: "error"}, status: :unprocessable_entity
    end

  end

  private

    def list_item_params
      params.permit(:index, :order, :title, :list_type, :id, :state)
    end


end
